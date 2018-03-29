import pytest
import rlp
from ethereum.tools import tester
from ethereum import utils
from plasma.root_chain import deployer
from plasma.child_chain.transaction import Transaction, UnsignedTransaction
from plasma.utils.merkle.fixed_merkle import FixedMerkle
from plasma.utils.utils import get_deposit_hash

null_address = b'\x00' * 20
null_sigs = b'\x00' * 130
value1 = 100
value2 = value1 * 2
owner1, key1 = tester.a1, tester.k1
owner2, key2 = tester.a2, tester.k2
authority_key = tester.k0
empty_block = FixedMerkle(16, [], True).root

deployer.compile_all()


def to_hex_address(address):
    return '0x' + address.hex()


def encode_utxo_pos(blknum, txindex, oindex):
    return (blknum * 1000000000) + (txindex * 10000) + (oindex * 1)


def decode_utxo_pos(utxo_pos):
    blknum = int(utxo_pos / 1000000000)
    txindex = int((utxo_pos % 1000000000) / 10000)
    oindex = int(utxo_pos - (blknum * 1000000000) - (txindex * 10000))
    return blknum, txindex, oindex


@pytest.fixture
def root_chain(t, get_contract):
    contract = get_contract('RootChain')
    t.chain.mine()

    return contract


@pytest.fixture
def valid_deposit(root_chain):
    # Create a valid input
    deposit_blknum = root_chain.getCurrentDepositBlockNumber()
    root_chain.deposit(value=value1, sender=key1)

    return deposit_blknum


@pytest.fixture
def valid_output(root_chain, valid_deposit):
    # Create a transaction spending the input
    tx = Transaction(valid_deposit, 0, 0, 0, 0, 0, owner1, value1, null_address, 0, 0, root_chain.currentChildBlock())
    tx_bytes = rlp.encode(tx, UnsignedTransaction)
    tx.sign1(key1)

    blknum = root_chain.currentChildBlock()
    merkle = FixedMerkle(16, [tx.merkle_hash], True)
    root_chain.submitBlock(merkle.root, blknum, sender=authority_key)

    # Calculate the UTXO position
    utxo_pos = encode_utxo_pos(blknum, 0, 0)

    # Create a membership proof
    proof = merkle.create_membership_proof(tx.merkle_hash)

    # Combine signatures
    sigs = tx.sig1 + tx.sig2

    return utxo_pos, tx_bytes, proof, sigs

@pytest.fixture
def valid_exit(root_chain, valid_deposit):
    # Start the exit
    root_chain.startDepositExit(valid_deposit, sender=key1)

    return root_chain, valid_deposit


def test_deposit_with_valid_value_should_succeed(t, root_chain, valid_deposit):
    # Assert that the block was created correctly
    deposit_block = root_chain.getBlock(valid_deposit)
    deposit_hash = get_deposit_hash(to_hex_address(owner1), value1)
    root = FixedMerkle(16, [deposit_hash], True).root
    timestamp = t.chain.head_state.timestamp

    assert deposit_block == [root, timestamp]


def test_start_exit_from_deposit_should_succeed(root_chain, valid_deposit):
    deposit_blknum = valid_deposit

    # Start the exit
    root_chain.startDepositExit(deposit_blknum, sender=key1)

    # Calculate the UTXO position
    utxo_pos = encode_utxo_pos(deposit_blknum, 0, 0)

    # Assert that the exit was inserted correctly
    assert root_chain.exits(utxo_pos) == [to_hex_address(owner1), value1]


def test_start_exit_from_valid_single_deposit_input_tx_should_succeed(root_chain, valid_deposit):
    # Create a transaction spending the input
    tx = Transaction(1, 0, 0, 0, 0, 0, owner1, value1, null_address, 0, 0, root_chain.currentChildBlock())
    tx.sign1(key1)

    blknum = root_chain.currentChildBlock()
    merkle1 = FixedMerkle(16, [tx.merkle_hash], True)
    root_chain.submitBlock(merkle1.root, blknum, sender=authority_key)

    # Calculate the UTXO position
    utxo_pos = encode_utxo_pos(blknum, 0, 0)

    # Create a membership proof
    proof1 = merkle1.create_membership_proof(tx.merkle_hash)

    # Combine signatures
    sigs = tx.sig1 + tx.sig2

    # Start the exit
    tx_bytes = rlp.encode(tx, UnsignedTransaction)
    root_chain.startExit(utxo_pos, tx_bytes, proof1, sigs,
                         '', '', '',
                         '', '', '',
                         sender=key1)

    # Assert that the exit was inserted correctly
    assert root_chain.exits(utxo_pos) == [to_hex_address(owner1), value1]


def test_start_exit_from_valid_single_nondeposit_input_tx_should_succeed(root_chain, valid_output):
    utxo_pos1, tx_bytes1, proof1, sigs1 = valid_output

    # Submit two empty blocks
    root_chain.submitBlock(empty_block, root_chain.currentChildBlock(), sender=authority_key)
    root_chain.submitBlock(empty_block, root_chain.currentChildBlock(), sender=authority_key)

    # Create a transaction spending the input
    tx2 = Transaction(*decode_utxo_pos(utxo_pos1), 0, 0, 0, owner1, value1, null_address, 0, 0, root_chain.currentChildBlock())
    tx2.sign1(key1)

    blknum2 = root_chain.currentChildBlock()
    merkle2 = FixedMerkle(16, [tx2.merkle_hash], True)
    root_chain.submitBlock(merkle2.root, blknum2, sender=authority_key)

    # Calculate the UTXO position
    utxo_pos2 = encode_utxo_pos(blknum2, 0, 0)

    # Create a membership proof
    proof2 = merkle2.create_membership_proof(tx2.merkle_hash)

    # Combine signatures
    sigs2 = tx2.sig1 + tx2.sig2

    # Start the exit
    tx_bytes2 = rlp.encode(tx2, UnsignedTransaction)
    root_chain.startExit(utxo_pos2, tx_bytes2, proof2, sigs2,
                         tx_bytes1, proof1, sigs1,
                         '', '', '',
                         sender=key1)

    # Assert that the exit was inserted correctly
    assert root_chain.exits(utxo_pos2) == [to_hex_address(owner1), value1]


def test_start_exit_from_invalid_single_input_tx_should_fail(root_chain, valid_output):
    utxo_pos1, tx_bytes1, proof1, sigs1 = valid_output

    # Create a transaction spending the input before waiting that the input is 3 blocks old
    tx2 = Transaction(*decode_utxo_pos(utxo_pos1), 0, 0, 0, owner1, value1, null_address, 0, 0, root_chain.currentChildBlock())
    tx2.sign1(key1)

    blknum2 = root_chain.currentChildBlock()
    merkle2 = FixedMerkle(16, [tx2.merkle_hash], True)
    root_chain.submitBlock(merkle2.root, blknum2, sender=authority_key)

    # Calculate the UTXO position
    utxo_pos2 = encode_utxo_pos(blknum2, 0, 0)

    # Create a membership proof
    proof2 = merkle2.create_membership_proof(tx2.merkle_hash)

    # Combine signatures
    sigs2 = tx2.sig1 + tx2.sig2

    # Start the exit
    tx_bytes2 = rlp.encode(tx2, UnsignedTransaction)
    with pytest.raises(tester.TransactionFailed):
        root_chain.startExit(utxo_pos2, tx_bytes2, proof2, sigs2,
                            tx_bytes1, proof1, sigs1,
                            '', '', '',
                            sender=key1)

    # Assert that the exit was not inserted
    assert root_chain.exits(utxo_pos2) == [to_hex_address(null_address), 0]

'''
def test_start_exit_from_valid_double_input_tx_should_succeed(root_chain):
    deposit_tx_bytes = rlp.encode(deposit_tx, UnsignedTransaction)

    # Create two valid inputs
    root_chain.deposit(value=value1)
    root_chain.deposit(value=value1)

    # Create a membership proof (same for both)
    merkle = FixedMerkle(16, [deposit_tx.merkle_hash], True)
    proof = merkle.create_membership_proof(deposit_tx.merkle_hash)

    # Submit two empty blocks
    root_chain.submitBlock(empty_block, sender=authority_key)
    root_chain.submitBlock(empty_block, sender=authority_key)

    # Create a transaction spending the inputs
    tx = Transaction(1, 0, 0, 2, 0, 0, owner1, value2, null_address, 0, 0)
    tx.sign1(key1)
    tx.sign2(key1)

    blknum = root_chain.currentChildBlock()
    merkle1 = FixedMerkle(16, [tx.merkle_hash], True)
    root_chain.submitBlock(merkle1.root, sender=authority_key)

    # Calculate the UTXO position
    utxo_pos = blknum * 1000000000

    # Create a membership proof
    proof1 = merkle1.create_membership_proof(tx.merkle_hash)

    # Combine signatures
    sigs = tx.sig1 + tx.sig2

    # Start the exit
    tx_bytes = rlp.encode(tx, UnsignedTransaction)
    root_chain.startExit(utxo_pos, tx_bytes, proof1, sigs,
                         deposit_tx_bytes, proof, null_sigs,
                         deposit_tx_bytes, proof, null_sigs,
                         sender=key1)

    # Assert that the exit was inserted correctly
    assert root_chain.exits(utxo_pos) == [to_hex_address(owner1), value2]


def test_start_exit_from_invalid_double_input_tx_should_fail(root_chain):
    deposit_tx_bytes = rlp.encode(deposit_tx, UnsignedTransaction)

    # Create a valid input
    deposit_blknum1 = root_chain.getCurrentDepositBlockNumber()
    root_chain.deposit(value=value1)

    # Create a membership proof (same for both)
    merkle = FixedMerkle(16, [deposit_tx.merkle_hash], True)
    proof = merkle.create_membership_proof(deposit_tx.merkle_hash)

    # Submit two empty blocks
    root_chain.submitBlock(empty_block, sender=authority_key)
    root_chain.submitBlock(empty_block, sender=authority_key)

    # Create another valid input, but don't add more blocks
    deposit_blknum2 = root_chain.getCurrentDepositBlockNumber()
    root_chain.deposit(value=value1)

    # Create a transaction spending the inputs
    tx = Transaction(deposit_blknum1, 0, 0, deposit_blknum2, 0, 0, owner1, value2, null_address, 0, 0)
    tx.sign1(key1)
    tx.sign2(key1)

    blknum = root_chain.currentChildBlock()
    merkle1 = FixedMerkle(16, [tx.merkle_hash], True)
    root_chain.submitBlock(merkle1.root, sender=authority_key)

    # Calculate the UTXO position
    utxo_pos = blknum * 1000000000

    # Create a membership proof
    proof1 = merkle1.create_membership_proof(tx.merkle_hash)

    # Combine signatures
    sigs = tx.sig1 + tx.sig2

    # Start the exit
    tx_bytes = rlp.encode(tx, UnsignedTransaction)
    with pytest.raises(tester.TransactionFailed):
        root_chain.startExit(utxo_pos, tx_bytes, proof1, sigs,
                             deposit_tx_bytes, proof, null_sigs,
                             deposit_tx_bytes, proof, null_sigs,
                             sender=key1)

    # Assert that the exit was inserted correctly
    assert root_chain.exits(utxo_pos) == [to_hex_address(null_address), 0, 0]


def test_valid_double_spend_challenge_should_succeed(valid_exit):
    root_chain, exit_utxo_pos = valid_exit

    # Submit two empty blocks
    root_chain.submitBlock(empty_block, sender=authority_key)
    root_chain.submitBlock(empty_block, sender=authority_key)

    # Create a double spending transaction spending the input
    tx = Transaction(1, 0, 0, 0, 0, 0, owner1, value1, null_address, 0, 0)
    tx.sign1(key1)

    blknum = root_chain.currentChildBlock()
    merkle1 = FixedMerkle(16, [tx.merkle_hash], True)
    root_chain.submitBlock(merkle1.root, sender=authority_key)

    # Calculate the UTXO position
    double_spend_utxo_pos = blknum * 1000000000

    # Create a membership proof
    proof1 = merkle1.create_membership_proof(tx.merkle_hash)

    # Combine signatures
    sigs = tx.sig1 + tx.sig2

    # Challenge the first exit with the double spend
    double_spend_tx_bytes = rlp.encode(tx, UnsignedTransaction)
    root_chain.challengeExit(double_spend_utxo_pos, exit_utxo_pos, double_spend_tx_bytes, proof1, sigs)

    assert root_chain.exits(exit_utxo_pos) == [to_hex_address(null_address), 0, 0]


def test_invalid_double_spend_challenge_should_fail(valid_exit):
    root_chain, exit_utxo_pos = valid_exit

    # Create a deposit for another user
    deposit_tx = Transaction(0, 0, 0, 0, 0, 0, owner2, value1, null_address, 0, 0)
    deposit_tx_bytes = rlp.encode(deposit_tx, UnsignedTransaction)

    deposit_blknum = root_chain.getCurrentDepositBlockNumber()
    root_chain.deposit(value=value1)

    # Submit two empty blocks
    root_chain.submitBlock(empty_block, sender=authority_key)
    root_chain.submitBlock(empty_block, sender=authority_key)

    # Create a transaction spending unrelated deposit
    tx = Transaction(deposit_blknum, 0, 0, 0, 0, 0, owner2, value1, null_address, 0, 0)
    tx.sign1(key2)

    blknum = root_chain.currentChildBlock()
    merkle1 = FixedMerkle(16, [tx.merkle_hash], True)
    root_chain.submitBlock(merkle1.root, sender=authority_key)

    # Calculate the UTXO position
    double_spend_utxo_pos = blknum * 1000000000

    # Create a membership proof
    proof1 = merkle1.create_membership_proof(tx.merkle_hash)

    # Combine signatures
    sigs = tx.sig1 + tx.sig2

    # Challenge the first exit with the double spend
    double_spend_tx_bytes = rlp.encode(tx, UnsignedTransaction)
    with pytest.raises(tester.TransactionFailed):
        root_chain.challengeExit(double_spend_utxo_pos, exit_utxo_pos, double_spend_tx_bytes, proof1, sigs)

    assert root_chain.exits(exit_utxo_pos) == [to_hex_address(owner1), value1, exit_utxo_pos]


def test_finalize_two_week_old_exit_should_succeed(t, valid_exit):
    root_chain, exit_utxo_pos = valid_exit

    # Advance the current block.timestamp by 2 weeks and 1 second
    week = 60 * 60 * 24 * 7
    t.chain.head_state.timestamp += (2 * week) + 1

    # Finalize exits
    initial_balance = t.chain.head_state.get_balance(owner1)
    root_chain.finalizeExits(sender=key2)
    final_balance = t.chain.head_state.get_balance(owner1)

    # Check that the exit was finalized
    assert final_balance == initial_balance + value1
    assert root_chain.exits(exit_utxo_pos) == [to_hex_address(null_address), 0, 0]


def test_finalize_new_exit_should_fail(t, valid_exit):
    root_chain, exit_utxo_pos = valid_exit

    # Attempt to finalize exits
    initial_balance = t.chain.head_state.get_balance(owner1)
    root_chain.finalizeExits(sender=key2)
    final_balance = t.chain.head_state.get_balance(owner1)

    # Check that the exit was not finalized
    assert final_balance == initial_balance
    assert root_chain.exits(exit_utxo_pos) == [to_hex_address(owner1), value1, exit_utxo_pos]
'''
