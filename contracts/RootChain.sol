pragma solidity ^0.4.0;

import "./Math.sol";
import "./Merkle.sol";
import "./PriorityQueue.sol";
import "./PlasmaCore.sol";

contract RootChain {
    using PlasmaCore for bytes;
    using PlasmaCore for uint256;

    /*
     * Storage
     */

    uint256 constant public MIN_EXIT_PERIOD = 1 weeks;
    uint256 constant public CHILD_BLOCK_INTERVAL = 1000;

    // WARNING: These placeholder bond values are entirely arbitrary.
    uint256 public exitBond = 31415926535 wei;

    address public operator;

    uint256 public nextChildBlock;
    uint256 public nextDepositBlock;

    mapping (uint256 => Block) public blocks;
    mapping (uint256 => Exit) public exits;

    PriorityQueue exitQueue;

    bytes32[16] zeroHashes;

    struct Block {
        bytes32 root;
        uint256 timestamp;
    }

    struct Exit {
        address owner;
        uint256 amount;
    }


    /*
     * Events
     */
    
    event BlockSubmitted(
        uint256 number,
        bytes32 root
    );

    event DepositCreated(
        address indexed depositor,
        uint256 amount
    );

    event ExitStarted(
        address indexed owner,
        uint256 outputId,
        uint256 amount
    );

    event ExitBlocked(
        address indexed challenger,
        uint256 outputId
    );


    /*
     * Modifiers
     */

    modifier onlyOperator() {
        require(msg.sender == operator);
        _;
    }

    modifier onlyWithValue(uint256 _value) {
        require(msg.value == _value);
        _;
    }

    
    /*
     * Constructor
     */
    
    constructor()
        public
    {
        operator = msg.sender;

        nextChildBlock = CHILD_BLOCK_INTERVAL;
        nextDepositBlock = 1;

        exitQueue = new PriorityQueue();

        // Pre-compute some hashes to save gas later.
        bytes32 zeroHash = keccak256(abi.encodePacked(uint256(0)));
        for (uint i = 0; i < 16; i++) {
            zeroHashes[i] = zeroHash;
            zeroHash = keccak256(abi.encodePacked(zeroHash, zeroHash));
        }
    }


    /*
     * Public functions
     */

    /**
     * @dev Allows the operator to submit a child block.
     * @param _root Merkle root of the block.
     */
    function submitBlock(bytes32 _root)
        public
        onlyOperator
    {
        uint256 currentChildBlock = nextChildBlock;

        // Create the block.
        blocks[currentChildBlock] = Block({
            root: _root,
            timestamp: block.timestamp
        });

        // Update the next child and deposit blocks.
        nextChildBlock += CHILD_BLOCK_INTERVAL;
        nextDepositBlock = 1;

        emit BlockSubmitted(currentChildBlock, _root);
    }

    /**
     * @dev Allows a user to submit a deposit.
     * @param _depositTx RLP encoded transaction to act as the deposit.
     */
    function deposit(bytes _depositTx)
        public
        payable
    {
        // Only allow a limited number of deposits per child block. 
        require(nextDepositBlock < CHILD_BLOCK_INTERVAL);

        // Decode the transaction.
        PlasmaCore.Transaction memory decodedTx = _depositTx.decode();

        // Check that the first output has the correct balance.
        require(decodedTx.outputs[0].amount == msg.value);

        // Check that the remaining outputs are all 0.
        for (uint i = 1; i < 4; i++) {
            require(decodedTx.outputs[i].amount == 0);
        }

        // Calculate the block root.
        bytes32 root = keccak256(_depositTx);
        for (i = 0; i < 16; i++) {
            root = keccak256(abi.encodePacked(root, zeroHashes[i]));
        }

        // Insert the deposit block.
        uint256 blknum = getDepositBlockNumber();
        blocks[blknum] = Block({
            root: root,
            timestamp: block.timestamp
        });

        nextDepositBlock++;

        emit DepositCreated(decodedTx.outputs[0].owner, msg.value);
    }

    /**
     * @dev Calculates the next deposit block.
     * @return Next deposit block number.
     */
    function getDepositBlockNumber()
        public
        view
        returns (uint256)
    {
        return nextChildBlock - CHILD_BLOCK_INTERVAL + nextDepositBlock;
    }

    /**
     * @dev Starts a withdrawal of a given output. Uses output-age priority.
     * @param _outputId Identifier of the exiting output.
     * @param _outputTx RLP encoded transaction that created the exiting output.
     * @param _outputTxInclusionProof A Merkle proof showing that the transaction was included.
     */
    function startExit(
        uint256 _outputId,
        bytes _outputTx,
        bytes _outputTxInclusionProof
    )
        public
        payable
        onlyWithValue(exitBond)
    {
        // Check that the output transaction actually created the output.
        require(_transactionIncluded(_outputTx, _outputId, _outputTxInclusionProof));

        // Decode the output ID.
        uint256 oindex = _outputId.getOindex();

        // Parse outputTx.
        PlasmaCore.TransactionOutput memory output = _outputTx.getOutput(oindex);

        // Only output owner can start an exit.
        require(msg.sender == output.owner);

        // Make sure this exit is valid.
        require(output.amount > 0);
        require(exits[_outputId].amount == 0);

        // Determine the exit's priority.
        uint256 exitPriority = _getExitPriority(_outputId);

        // Insert the exit into the queue and update the exit mapping.
        exitQueue.insert(exitPriority);
        exits[_outputId] = Exit({
            owner: output.owner,
            amount: output.amount
        });

        emit ExitStarted(output.owner, _outputId, output.amount);
    }

    /**
     * @dev Blocks an exit by showing the exiting output was spent.
     * @param _outputId Identifier of the exiting output to challenge.
     * @param _challengeTx RLP encoded transaction that spends the exiting output.
     * @param _challengeTxId Identifier of the spending transaction.
     * @param _inputIndex Which input to the challenging tx corresponds to the exiting output.
     * @param _challengeTxConfirmationSig Signature that confirms the spend.
     */
    function challengeExit(
        uint192 _outputId,
        bytes _challengeTx,
        uint256 _challengeTxId,
        uint256 _inputIndex,
        bytes _challengeTxConfirmationSig
    )
        public
    {
        // Check that the output is being used as an input to the challenging tx.
        uint256 inputId = _challengeTx.getInputId(_inputIndex);
        require(inputId == _outputId);

        // Check that the challenging tx is signed by the output's owner.
        address owner = exits[_outputId].owner;
        bytes32 root = blocks[_challengeTxId.getBlknum()].root;
        bytes32 confirmationHash = keccak256(abi.encodePacked(_challengeTx, root));
        require(owner == ECRecovery.recover(confirmationHash, _challengeTxConfirmationSig));

        // Delete the exit.
        delete exits[_outputId];

        // Send a bond to the challenger.
        msg.sender.transfer(exitBond);

        emit ExitBlocked(msg.sender, _outputId);
    }

    /**
     * @dev Processes any exits that have completed the challenge period.
     */
    function processExits()
        public
    {
        uint192 outputId;
        uint64 exitableTimestamp;

        while (exitQueue.currentSize() > 0) {
            // Pull the next exit.
            (outputId, exitableTimestamp) = _getNextExit();

            // Check that the exit can be processed.
            if (exitableTimestamp > block.timestamp) {
                return;
            }

            Exit memory exit = exits[outputId];
            if (exit.owner != address(0)) {
                exit.owner.transfer(exit.amount + exitBond);
                delete exit.owner;
            }

            // Delete the minimum from the queue.
            exitQueue.delMin();
        }
    }


    /*
     * Internal functions
     */

    /**
     * @dev Checks that a given transaction was included in a block and created a specified output.
     * @param _tx RLP encoded transaction to verify.
     * @param _transactionId Unique transaction identifier for the encoded transaction.
     * @param _txInclusionProof Proof that the transaction was in a block.
     * @return True if the transaction was in a block and created the output. False otherwise.
     */
    function _transactionIncluded(bytes _tx, uint256 _transactionId, bytes _txInclusionProof)
        internal
        view
        returns (bool)
    {
        // Decode the transaction ID.
        uint256 blknum = _transactionId.getBlknum();
        uint256 txindex = _transactionId.getTxindex();

        // Check that the transaction was correctly included.
        bytes32 blockRoot = blocks[blknum].root;
        bytes32 leafHash = keccak256(_tx);
        return Merkle.checkMembership(leafHash, txindex, blockRoot, _txInclusionProof);
    }

    /**
     * @dev Given an output ID, determines when it's exitable, if it were to be exited now.
     * @param _outputId Output identifier.
     * @return uint256 Timestamp after which this output is exitable.
     */
    function _getExitableTimestamp(uint256 _outputId)
        internal
        view
        returns (uint256)
    {
        uint256 blknum = _outputId.getBlknum();
        return Math.max(blocks[blknum].timestamp + (MIN_EXIT_PERIOD * 2), block.timestamp + MIN_EXIT_PERIOD);
    }

    /**
     * @dev Given an output ID, returns an exit priority.
     * @param _outputId Position of the exit in the blockchain.
     * @return An exit priority.
     */
    function _getExitPriority(uint256 _outputId)
        internal
        view
        returns (uint256)
    {
        return _getExitableTimestamp(_outputId) << 192 | uint192(_outputId);
    }

    /**
     * @dev Returns the next exit to be processed.
     * @return A tuple containing the unique exit ID and timestamp for when the next exit is processable.
     */
    function _getNextExit()
        internal
        view
        returns (uint192, uint64)
    {
        uint256 priority = exitQueue.getMin();
        uint192 uniqueId = uint192(priority);
        uint64 exitableTimestamp = uint64(priority >> 192);
        return (uniqueId, exitableTimestamp);
    }
}
