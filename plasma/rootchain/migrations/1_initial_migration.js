var Migrations = artifacts.require("./Migrations.sol");
var RootChain = artifacts.require("./RootChain.sol");

module.exports = function(deployer) {
  deployer.deploy(Migrations);

  deployer.deploy(RootChain);
};
