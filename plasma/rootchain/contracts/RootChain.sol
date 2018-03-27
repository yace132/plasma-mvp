pragma solidity ^0.4.19;

import "./ByteUtils.sol";
import "./Math.sol";
import "./Merkle.sol";
import "./PriorityQueue.sol";
import "./RLP.sol";
import "./SafeMath.sol";
import "./Validate.sol";

/**
 * @title RootChain
 * @dev This contract secures a UTXO-based Plasma child chain
 */

contract RootChain {
    using SafeMath for uint256;
    using RLP for bytes;
    using RLP for RLP.RLPItem;
    using RLP for RLP.Iterator;
    using Merkle for bytes32;

    /*
     * Events
     */
    
    event Deposit(
        address indexed _depositor,
        uint256 indexed _blknum,
        uint256 amount
    );
    event ExitStarted(
        address indexed _exitor,
        uint256 indexed utxoPos,
        uint256 amount
    );


    /*
     * Structs
     */

    struct Exit {
        address exitor;
        uint256 amount;
    }

    struct ChildBlock {
        bytes32 root;
        uint256 timestamp;
    }


    /*
     * Storage
     */

    mapping (uint256 => ChildBlock) public childChain;
    mapping (uint256 => Exit) public exits;

    PriorityQueue exitQueue;

    address public authority;

    uint256 public childBlockInterval;
    uint256 public currentChildBlock;
    uint256 public currentDepositBlock;
    uint256 public transactionTimeout;

    bytes32[16] zeroHashes;


    /*
     * Modifiers
     */

    modifier onlyAuthority() {
        require(msg.sender == authority);
        _;
    }


    /*
     * Public Functions
     */

    function RootChain()
        public
    {
        exitQueue = new PriorityQueue();

        authority = msg.sender;

        childBlockInterval = 1000;
        currentChildBlock = childBlockInterval;
        currentDepositBlock = 1;
        transactionTimeout = 2;

        generateZeroHashes();
    }

    /**
     * @dev Allows the chain operator to submit a block
     * @param root Merkle root of the child chain block
     * @param blknum Number of the block being submitted
     */
    function submitBlock(bytes32 root, uint256 blknum)
        public
        onlyAuthority
    {
        require(blknum == currentChildBlock);

        childChain[currentChildBlock] = ChildBlock({
            root: root,
            timestamp: block.timestamp
        });

        currentChildBlock = currentChildBlock.add(childBlockInterval);
        currentDepositBlock = 1;
    }

    /**
     * @dev Allows a user to deposit funds into the Plasma chain
     */
    function deposit()
        public
        payable
    {
        require(currentDepositBlock < childBlockInterval);

        bytes32 root = calculateDepositRoot(msg.sender, msg.value);

        uint256 blknum = getCurrentDepositBlockNumber();
        childChain[blknum] = ChildBlock({
            root: root,
            timestamp: block.timestamp
        });

        currentDepositBlock = currentDepositBlock.add(1);

        Deposit(msg.sender, blknum, msg.value);
    }

    /**
     * @dev Starts an exit from a UTXO created by a deposit
     * @param blknum Number of the deposit block in which this deposit was included
     * @param amount Value of the deposit
     */
    function startDepositExit(uint256 blknum, uint256 amount)
        public
    {
        require(isDepositBlock(blknum));

        bytes32 root = calculateDepositRoot(msg.sender, amount);
        require(root == childChain[blknum].root);

        uint256 utxoPos = encodeUtxoPos(blknum, 0, 0);
        addExitToQueue(utxoPos, msg.sender, amount);
    }

    /**
     * @dev Starts an exit from a non-deposit UTXO
     * @param utxoPos Position of the UTXO being exited
     * @param txBytes RLP encoded transaction that created this UTXO
     * @param proof A Merkle proof showing that this transaction was actually included at the specified utxoPos
     * @param sigs Signatures that prove the transaction is valid
     * @param inputTxBytes1 RLP encoded transaction that created the first input to this UTXO
     * @param inputProof1 A Merkle proof showing that the first input was included
     * @param inputSigs1 Signatures that prove the first input is valid
     * @param inputTxBytes2 RLP encoded transaction that created the second input to this UTXO
     * @param inputProof2 A Merkle proof showing that the second input was included
     * @param inputSigs2 Signatures that prove the second input is valid
     */
    function startExit(uint256 utxoPos, bytes txBytes, bytes proof, bytes sigs,
                       bytes inputTxBytes1, bytes inputProof1, bytes inputSigs1,
                       bytes inputTxBytes2, bytes inputProof2, bytes inputSigs2)
        public
    {
        require(isValidUtxo(utxoPos, txBytes, proof, sigs));

        require(hasValidInputs(txBytes, inputTxBytes1, inputProof1, inputSigs1, inputTxBytes2, inputProof2, inputSigs2));

        uint256 oindex;
        ( , , oindex) = decodeUtxoPos(utxoPos);

        address exitor;
        uint256 amount;
        (exitor, amount) = getOutput(txBytes, oindex);

        addExitToQueue(utxoPos, exitor, amount);
    }


    /*
     * Private Functions
     */

    /**
     * @dev Pre-generates hashes required to create deposit transactions
     */
    function generateZeroHashes()
        private
    {
        bytes32 zeroHash;
        for (uint256 i = 0; i < 16; i++) {
            zeroHashes[i] = zeroHash;
            zeroHash = keccak256(zeroHash, zeroHash);
        }
    }

    /**
     * @dev Calculates the block root for a deposit transaction
     * @param depositor Address of the depositor
     * @param amount Amount deposited
     * @return The root to be used for the deposit block
     */
    function calculateDepositRoot(address depositor, uint256 amount)
        private
        view
        returns (bytes32)
    {
        bytes32 root = keccak256(depositor, amount);
        for (uint256 i = 0; i < 16; i++) {
            root = keccak256(root, zeroHashes[i]);
        }

        return root;
    }

    /**
     * @dev Inserts an exit into the priority queue
     * @param utxoPos Position of the UTXO being exited
     * @param exitor Address of the user who owns this exit
     * @param amount Amount being exited
     */
    function addExitToQueue(uint256 utxoPos, address exitor, uint256 amount)
        private
    {
        require(amount > 0);
        require(exits[utxoPos].amount == 0);

        uint256 blknum;
        (blknum, , ) = decodeUtxoPos(utxoPos);

        uint256 priority = Math.max(childChain[blknum].timestamp, block.timestamp - 1 weeks);
        uint256 combinedPriority = priority << 128 | utxoPos;

        exitQueue.insert(combinedPriority);
        exits[utxoPos] = Exit({
            exitor: exitor,
            amount: amount
        });

        ExitStarted(exitor, utxoPos, amount);
    }

    
    /*
     * Constant Functions
     */

    /**
     * @dev Returns the full block number of the current deposit block
     * @return The current deposit block number
     */
    function getCurrentDepositBlockNumber()
        public
        view
        returns (uint256)
    {
        return currentChildBlock.sub(childBlockInterval).add(currentDepositBlock);
    }

    /**
     * @dev Calculates a utxoPos from its components
     * @param blknum Block this UTXO was included in
     * @param txindex Index of the transaction that created this UTXO
     * @param oindex Index of the UTXO in the transaction
     * @return A utxoPos from its components
     */
    function encodeUtxoPos(uint256 blknum, uint256 txindex, uint256 oindex)
        public
        pure
        returns (uint256)
    {
        return (blknum * 1000000000) + (txindex * 10000) + (oindex * 1);
    }

    /**
     * @dev Decomposes a utxoPos into its parts
     * @param utxoPos A UTXO position
     * @return The three components (blknum, txindex, oindex) that make up a utxoPos
     */
    function decodeUtxoPos(uint256 utxoPos)
        public
        pure
        returns (uint256, uint256, uint256)
    {
        uint256 blknum = utxoPos / 1000000000;
        uint256 txindex = (utxoPos % 1000000000) / 10000;
        uint256 oindex = utxoPos - blknum * 1000000000 - txindex * 10000;

        return (blknum, txindex, oindex);
    }

    /**
     * @dev Checks that the difference between two blocks is less than the transaction timeout
     * @param blknum1 First block number to check
     * @param blknum2 Second block number to check
     * @return true if the difference is less than the timeout, false otherwise
     */
    function isWithinTimeout(uint256 blknum1, uint256 blknum2)
        public
        view
        returns (bool)
    {
        return (blknum1 - blknum2) / childBlockInterval <= transactionTimeout;
    }

    /**
     * @dev Checks if a block is a deposit block
     * @param blknum Block number to check
     * @return true if the block is a deposit block, false otherwise
     */
    function isDepositBlock(uint256 blknum)
        public
        view
        returns (bool)
    {
        return blknum % childBlockInterval > 0;
    }

    /**
     * @dev Returns the owner and amount of an output given the encoded transaction
     * @param txBytes RLP encoded transaction
     * @param oindex Which output to return
     * @return The owner and amount of this output
     */
    function getOutput(bytes txBytes, uint256 oindex)
        public
        view
        returns (address, uint256)
    {
        RLP.RLPItem[] memory txList = txBytes.toRLPItem().toList(12);

        uint256 offset = 2 * oindex;
        address owner = txList[6 + offset].toAddress();
        uint256 amount = txList[7 + offset].toUint();
        return (owner, amount);
    }

    /**
     * @dev Checks if a UTXO is valid
     * @param utxoPos Position of this UTXO
     * @param txBytes RLP encoded transaction that created this UTXO
     * @param proof A Merkle proof showing that this UTXO was included at the specified position
     * @param sigs Signatures to verify
     * @return true if the UTXO is valid, throws otherwise
     */
    function isValidUtxo(uint256 utxoPos, bytes txBytes, bytes proof, bytes sigs)
        public
        view
        returns (bool)
    {
        uint256 blknum;
        uint256 txindex;
        uint256 oindex;
        (blknum, txindex, oindex) = decodeUtxoPos(utxoPos);

        return isValidUtxo(blknum, txindex, oindex, txBytes, proof, sigs);
    }

    /**
     * @dev Checks if a UTXO is valid
     * @param blknum Block in which this UTXO was included
     * @param txindex Index of the transaction that created this UTXO
     * @param oindex Index of the UTXO in the transaction
     * @param txBytes RLP encoded transaction that created this UTXO
     * @param proof A Merkle proof showing that this UTXO was included at the specified position
     * @param sigs Signatures to verify
     * @return true if the UTXO is valid, throws otherwise
     */
    function isValidUtxo(uint256 blknum, uint256 txindex, uint256 oindex, bytes txBytes, bytes proof, bytes sigs)
        public
        view
        returns (bool)
    {
        RLP.RLPItem[] memory txList = txBytes.toRLPItem().toList(12);

        require(isWithinTimeout(blknum, txList[11].toUint()));
        require(msg.sender == txList[6 + 2 * oindex].toAddress());
        require(Validate.checkSigs(txHash, txList[0].toUint(), txList[3].toUint(), sigs));

        bytes32 txHash = keccak256(txBytes);
        bytes32 merkleHash = keccak256(txHash, ByteUtils.slice(sigs, 0, 130));
        bytes32 root = childChain[blknum].root;
        require(merkleHash.checkMembership(txindex, root, proof));

        return true;
    }

    /**
     * @dev Checks if a transaction has valid inputs
     * @param txBytes RLP encoded transaction to check
     * @param inputTxBytes1 RLP encoded transaction that created the first input to this transaction
     * @param inputProof1 A Merkle proof showing that the first input was included
     * @param inputSigs1 Signatures that prove the first input is valid
     * @param inputTxBytes2 RLP encoded transaction that created the second input to this transaction
     * @param inputProof2 A Merkle proof showing that the second input was included
     * @param inputSigs2 Signatures that prove the second input is valid
     * @return true if the UTXO is valid, throws otherwise
     */
    function hasValidInputs(bytes txBytes,
                            bytes inputTxBytes1, bytes inputProof1, bytes inputSigs1,
                            bytes inputTxBytes2, bytes inputProof2, bytes inputSigs2)
        public
        view
        returns (bool)
    {
        RLP.RLPItem[] memory txList = txBytes.toRLPItem().toList(12);

        uint256 inputBlknum1 = txList[0].toUint();
        uint256 inputBlknum2 = txList[3].toUint();

        require(inputBlknum1 > 0 && inputBlknum2 > 0);

        require(!isWithinTimeout(currentChildBlock, inputBlknum1));
        require(isValidUtxo(inputBlknum1, txList[1].toUint(), txList[2].toUint(), inputTxBytes1, inputProof1, inputSigs1));

        require(!isWithinTimeout(currentChildBlock, inputBlknum2));
        require(isValidUtxo(inputBlknum2, txList[4].toUint(), txList[5].toUint(), inputTxBytes2, inputProof2, inputSigs2));

        return true;
    }
}
