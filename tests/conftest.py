import pytest
from ethereum.tools import tester
from ethereum.abi import ContractTranslator
from ethereum import utils
from plasma.utils import utils as plasma_utils
from plasma.root_chain import deployer
import os


OWN_DIR = os.path.dirname(os.path.realpath(__file__))


@pytest.fixture
def t():
    tester.chain = tester.Chain()
    return tester


@pytest.fixture
def u():
    utils.plasma = plasma_utils
    return utils


@pytest.fixture
def get_contract(t, u):
    def create_contract(contract_name, args=(), sender=t.k0):
        abi, hexcode = deployer.get_contract_data(contract_name)

        bytecode = u.decode_hex(hexcode)
        ct = ContractTranslator(abi)
        code = bytecode + (ct.encode_constructor_arguments(args) if args else b'')

        address = t.chain.tx(sender=sender, to=b'', startgas=4700000, value=0, data=code)
        return t.ABIContract(t.chain, abi, address)
    return create_contract
