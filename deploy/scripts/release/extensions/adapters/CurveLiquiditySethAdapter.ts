import { CurveLiquiditySethAdapterArgs } from '@enzymefinance/protocol';
import { DeployFunction } from 'hardhat-deploy/types';

import { loadConfig } from '../../../../utils/config';

const fn: DeployFunction = async function (hre) {
  const {
    deployments: { deploy, get },
    ethers: { getSigners },
  } = hre;

  const deployer = (await getSigners())[0];
  const config = await loadConfig(hre);
  const integrationManager = await get('IntegrationManager');

  await deploy('CurveLiquiditySethAdapter', {
    args: [
      integrationManager.address,
      config.curve.pools.seth.liquidityGaugeToken,
      config.curve.pools.seth.lpToken,
      config.curve.minter,
      config.curve.pools.seth.pool,
      config.primitives.crv,
      config.synthetix.synths.seth,
      config.weth,
    ] as CurveLiquiditySethAdapterArgs,
    from: deployer.address,
    linkedData: {
      type: 'ADAPTER',
      nonSlippageAdapter: true,
    },
    log: true,
    skipIfAlreadyDeployed: true,
  });
};

fn.tags = ['Release', 'Adapters', 'CurveLiquiditySethAdapter'];
fn.dependencies = ['Config', 'IntegrationManager'];

export default fn;
