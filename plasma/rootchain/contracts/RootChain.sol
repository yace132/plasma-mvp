pragma solidity ^0.4.21;

import "./Math.sol";
import "./PriorityQueue.sol";
import "./SafeMath.sol";

/**
 * @title RootChain
 * @dev This contract secures a UTXO-based Plasma child chain
 */

contract RootChain {
    using SafeMath for uint256;

    /*
     * Events
     */
    
    event Deposit(address depositor, uint256 amount, uint256 blknum);
    event ExitStarted(address exitor, uint256 amount, uint256 utxoPos);


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

        emit Deposit(msg.sender, msg.value, blknum);
    }

    /**
     * @dev Starts an exit from a UTXO created by a deposit
     * @param blknum Number of the deposit block in which this deposit was included
     * @param amount Value of the deposit
     */
    function startDepositExit(uint256 blknum, uint256 amount)
        public
    {
        bytes32 root = calculateDepositRoot(msg.sender, amount);
        require(root == childChain[blknum].root);

        uint256 utxoPos = encodeUtxoPos(blknum, 0, 0);
        addExitToQueue(utxoPos, msg.sender, amount);
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

        emit ExitStarted(exitor, amount, utxoPos);
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
}
