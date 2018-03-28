import os
import json
from solc import compile_standard
from web3 import Web3, HTTPProvider
from web3.contract import ConciseContract

own_directory = os.path.dirname(os.path.realpath(__file__))
contracts_directory = own_directory + '/contracts'
output_directory = own_directory + '/build'

def get_contracts():
    contracts = {
        file_name: {
            'urls': [os.path.realpath(os.path.join(r, file_name))]
        } for r, d, f in os.walk(contracts_directory) for file_name in f
    }
    return contracts

def compile_all():
    # Solidity input JSON 
    # Learn more here: https://solidity.readthedocs.io/en/develop/using-the-compiler.html#compiler-input-and-output-json-description
    solc_input = {
        'language': 'Solidity',
        'sources': get_contracts()
    }

    # Compile the contracts
    compilation_result = compile_standard(solc_input, allow_paths=contracts_directory)

    # Create the output folder if it doesn't already exist
    os.makedirs(output_directory, exist_ok=True)

    # Write the contract ABI to output files
    compiled_contracts = compilation_result['contracts']
    for contract_file in compiled_contracts:
        for contract in compiled_contracts[contract_file]:
            contract_name = contract.split('.')[0]
            contract_data = compiled_contracts[contract_file][contract_name]

            contract_data_path = output_directory + '/{0}.json'.format(contract_name)
            with open(contract_data_path, "w+") as contract_data_file:
                json.dump(contract_data, contract_data_file)

def deploy_contract(contract_name, provider=HTTPProvider('http://localhost:8545'), gas=5000000, args=()):
    contract_data_path = output_directory + '/{0}.json'.format(contract_name)
    with open(contract_data_path, 'r') as contract_data_file:
        contract_data = json.load(contract_data_file)
    
    abi = contract_data['abi']
    bytecode = contract_data['evm']['bytecode']['object']

    w3 = Web3(provider)
    contract = w3.eth.contract(abi=abi, bytecode=bytecode)

    # Get transaction hash from deployed contract
    tx_hash = contract.deploy(transaction={
        'from': w3.eth.accounts[0],
        'gas': gas
    }, args=args)

    # Get tx receipt to get contract address
    tx_receipt = w3.eth.getTransactionReceipt(tx_hash)
    contract_address = tx_receipt['contractAddress']

    # Contract instance in concise mode
    contract_instance = w3.eth.contract(abi, contract_address, ContractFactoryClass=ConciseContract)

    print("Successfully deployed {0} contract!".format(contract_name))

    return contract_instance
