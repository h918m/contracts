import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { CONTRACTS } from "./constants";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();
    const authorityDeployment = await deployments.get(CONTRACTS.authority);

    await deploy(CONTRACTS.ohm, {
        from: deployer,
        args: [authorityDeployment.address],
        log: true,
    });
};

func.tags = [CONTRACTS.ohm, "staking", "tokens"];
export default func;
