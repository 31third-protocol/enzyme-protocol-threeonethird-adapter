import type { SendFunction } from '@enzymefinance/ethers';
import { randomAddress } from '@enzymefinance/ethers';
import type { AllowedDepositRecipientsPolicy, FundDeployer, PolicyManager, VaultLib } from '@enzymefinance/protocol';
import {
  addressListRegistryPolicyArgs,
  AddressListUpdateType,
  addTrackedAssetsToVaultArgs,
  ComptrollerLib,
  encodeArgs,
  GasRelayPaymasterLib,
  IntegrationManagerActionId,
  ITestGsnRelayHub,
  ITestStandardToken,
  ONE_YEAR_IN_SECONDS,
  sighash,
} from '@enzymefinance/protocol';
import type { ProtocolDeployment, SignerWithAddress } from '@enzymefinance/testutils';
import {
  addNewAssetsToFund,
  assertDidRelay,
  assertDidRelaySuccessfully,
  assertEvent,
  assertPaymasterDidRejectForReason,
  buySharesFunction,
  calcMlnValueAndBurnAmountForSharesBuyback,
  createFundDeployer,
  createMigrationRequest,
  createNewFund,
  deployGasRelayerPaymaster,
  deployProtocolFixture,
  getAssetBalances,
  getAssetUnit,
  redeemSharesInKind,
  relayTransaction,
  setAccountBalance,
  transactionTimestamp,
} from '@enzymefinance/testutils';
import { BigNumber, constants, utils } from 'ethers';

let depositCooldown: number, depositMaxTotal: BigNumber;
let fork: ProtocolDeployment;

beforeEach(async () => {
  fork = await deployProtocolFixture();
  await global.provider.send('hardhat_impersonateAccount', [fork.config.gsn.relayWorker]);

  depositCooldown = fork.config.gsn.depositCooldown;
  depositMaxTotal = BigNumber.from(fork.config.gsn.depositMaxTotal);
});

describe('gas relayer', () => {
  let wrappedNativeAsset: ITestStandardToken;
  let fundOwner: SignerWithAddress;
  let comptrollerProxy: ComptrollerLib, vaultProxy: VaultLib;
  let miscSendFunction: SendFunction<any>;

  beforeEach(async () => {
    // Create fund
    [fundOwner] = fork.accounts;
    wrappedNativeAsset = new ITestStandardToken(fork.config.wrappedNativeAsset, provider);
    const newFundRes = await createNewFund({
      denominationAsset: wrappedNativeAsset,
      fundDeployer: fork.deployment.fundDeployer,
      fundOwner,
      signer: fundOwner,
    });
    comptrollerProxy = newFundRes.comptrollerProxy;
    vaultProxy = newFundRes.vaultProxy;

    // Seed fund with more than enough wrapped native asset for multiple gas relayer deposits
    await setAccountBalance({
      account: vaultProxy,
      amount: depositMaxTotal.mul(11),
      provider,
      token: wrappedNativeAsset,
    });

    // Can be any arbitrary call that should never fail
    miscSendFunction = comptrollerProxy.callOnExtension.args(
      fork.deployment.integrationManager.address,
      IntegrationManagerActionId.AddTrackedAssetsToVault,
      addTrackedAssetsToVaultArgs({ assets: [fork.config.primitives.usdt] }),
    );
  });

  it('deploys correctly from ComptrollerProxy', async () => {
    const preTxVaultNativeAssetBalance = await wrappedNativeAsset.balanceOf(vaultProxy);

    const receipt = await comptrollerProxy.deployGasRelayPaymaster();

    const paymasterAddress = await comptrollerProxy.getGasRelayPaymaster();
    expect(paymasterAddress).not.toMatchAddress(constants.AddressZero);

    const paymaster = new GasRelayPaymasterLib(paymasterAddress, provider);

    // Gas relayer deposit should be taken from the vault
    expect(await paymaster.getRelayHubDeposit()).toEqBigNumber(depositMaxTotal);
    expect(await wrappedNativeAsset.balanceOf(vaultProxy)).toEqBigNumber(
      preTxVaultNativeAssetBalance.sub(depositMaxTotal),
    );

    // Last deposit timestamp should have been updated
    expect(await paymaster.getLastDepositTimestamp()).toEqBigNumber(await transactionTimestamp(receipt));

    // Assert expected events
    assertEvent(receipt, paymaster.abi.getEvent('Deposited'), { amount: depositMaxTotal });
    assertEvent(receipt, comptrollerProxy.abi.getEvent('GasRelayPaymasterSet'), {
      gasRelayPaymaster: paymaster.address,
    });
  });

  it('fund owner should be able to withdraw deposit directly from gas relayer', async () => {
    const paymaster = await deployGasRelayerPaymaster({
      signer: fundOwner,
      comptrollerProxy,
    });

    const preTxVaultBalance = await wrappedNativeAsset.balanceOf(vaultProxy);

    await paymaster.withdrawBalance();

    expect(await wrappedNativeAsset.balanceOf(vaultProxy)).toEqBigNumber(preTxVaultBalance.add(depositMaxTotal));
  });

  it('does not allow a high baseRelayFee', async () => {
    const paymaster = await deployGasRelayerPaymaster({
      signer: fundOwner,
      comptrollerProxy,
    });

    const receipt = await relayTransaction({
      paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
      relayHub: fork.config.gsn.relayHub,
      relayWorker: fork.config.gsn.relayWorker,
      sendFunction: miscSendFunction,
      vaultPaymaster: paymaster.address,
      baseRelayFee: BigNumber.from(fork.config.gsn.relayFeeMaxBase).add(1),
    });

    assertPaymasterDidRejectForReason(receipt, 'High baseRelayFee');
  });

  it('does not allow a high pctRelayFee', async () => {
    const paymaster = await deployGasRelayerPaymaster({
      signer: fundOwner,
      comptrollerProxy,
    });

    const receipt = await relayTransaction({
      paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
      relayHub: fork.config.gsn.relayHub,
      relayWorker: fork.config.gsn.relayWorker,
      sendFunction: miscSendFunction,
      vaultPaymaster: paymaster.address,
      pctRelayFee: BigNumber.from(fork.config.gsn.relayFeeMaxPercent).add(1),
    });

    assertPaymasterDidRejectForReason(receipt, 'High pctRelayFee');
  });

  describe('top up', () => {
    let paymaster: GasRelayPaymasterLib;

    beforeEach(async () => {
      paymaster = await deployGasRelayerPaymaster({
        signer: fundOwner,
        comptrollerProxy,
      });
    });

    it('should NOT top up: deposit is at max', async () => {
      // Warp beyond the deposit cooldown period
      await provider.send('evm_increaseTime', [depositCooldown + 1]);

      const preRelayLastDepositTimestamp = await paymaster.getLastDepositTimestamp();

      assertDidRelaySuccessfully(
        await relayTransaction({
          paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
          relayHub: fork.config.gsn.relayHub,
          relayWorker: fork.config.gsn.relayWorker,
          sendFunction: miscSendFunction,
          vaultPaymaster: paymaster.address,
        }),
      );

      expect(await paymaster.getLastDepositTimestamp()).toEqBigNumber(preRelayLastDepositTimestamp);
    });

    it('should NOT top up: within the deposit cooldown period', async () => {
      const preRelayLastDepositTimestamp = await paymaster.getLastDepositTimestamp();

      // No top-up
      assertDidRelaySuccessfully(
        await relayTransaction({
          paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
          relayHub: fork.config.gsn.relayHub,
          relayWorker: fork.config.gsn.relayWorker,
          sendFunction: miscSendFunction,
          vaultPaymaster: paymaster.address,
        }),
      );

      // Some relay hub balance has been used
      expect(await paymaster.getRelayHubDeposit()).toBeLtBigNumber(depositMaxTotal);

      // Warp to just before end of cooldown period
      await provider.send('evm_increaseTime', [depositCooldown - 60]);

      // No top-up
      assertDidRelaySuccessfully(
        await relayTransaction({
          paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
          relayHub: fork.config.gsn.relayHub,
          relayWorker: fork.config.gsn.relayWorker,
          sendFunction: miscSendFunction,
          vaultPaymaster: paymaster.address,
        }),
      );

      expect(await paymaster.getLastDepositTimestamp()).toEqBigNumber(preRelayLastDepositTimestamp);
    });

    it('should NOT top up: top-up flag set to false', async () => {
      const preRelayLastDepositTimestamp = await paymaster.getLastDepositTimestamp();

      // No top-up
      assertDidRelaySuccessfully(
        await relayTransaction({
          paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
          relayHub: fork.config.gsn.relayHub,
          relayWorker: fork.config.gsn.relayWorker,
          sendFunction: miscSendFunction,
          vaultPaymaster: paymaster.address,
        }),
      );

      // Some relay hub balance has been used
      expect(await paymaster.getRelayHubDeposit()).toBeLtBigNumber(depositMaxTotal);

      // Warp beyond end of cooldown period
      await provider.send('evm_increaseTime', [depositCooldown + 1]);

      assertDidRelaySuccessfully(
        await relayTransaction({
          paymasterData: utils.defaultAbiCoder.encode(['bool'], [false]),
          relayHub: fork.config.gsn.relayHub,
          relayWorker: fork.config.gsn.relayWorker,
          sendFunction: miscSendFunction,
          vaultPaymaster: paymaster.address,
        }),
      );

      expect(await paymaster.getLastDepositTimestamp()).toEqBigNumber(preRelayLastDepositTimestamp);
    });

    it('should top up correctly', async () => {
      // No top-up
      assertDidRelaySuccessfully(
        await relayTransaction({
          paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
          relayHub: fork.config.gsn.relayHub,
          relayWorker: fork.config.gsn.relayWorker,
          sendFunction: miscSendFunction,
          vaultPaymaster: paymaster.address,
        }),
      );

      // Some relay hub balance has been used
      expect(await paymaster.getRelayHubDeposit()).toBeLtBigNumber(depositMaxTotal);

      // Warp beyond end of cooldown period
      await provider.send('evm_increaseTime', [depositCooldown + 1]);

      const preTxRelayHubDeposit = await paymaster.getRelayHubDeposit();
      const preTxVaultBalance = await wrappedNativeAsset.balanceOf(vaultProxy);

      const relayReceipt = await relayTransaction({
        paymasterData: utils.defaultAbiCoder.encode(['bool'], [true]),
        relayHub: fork.config.gsn.relayHub,
        relayWorker: fork.config.gsn.relayWorker,
        sendFunction: miscSendFunction,
        vaultPaymaster: paymaster.address,
      });

      const relayed = assertDidRelay(relayReceipt);
      assertDidRelaySuccessfully(relayReceipt);

      // New last deposit timestamp
      expect(await paymaster.getLastDepositTimestamp()).toEqBigNumber(await transactionTimestamp(relayReceipt));

      // Correct balance was taken from the vault
      const postTxVaultBalance = await wrappedNativeAsset.balanceOf(vaultProxy);
      const vaultDebit = preTxVaultBalance.sub(postTxVaultBalance);
      expect(vaultDebit).toEqBigNumber(depositMaxTotal.sub(preTxRelayHubDeposit));

      // RelayHub balance is the max deposit net relayed tx cost
      const postTxRelayHubDeposit = await paymaster.getRelayHubDeposit();
      expect(postTxRelayHubDeposit).toEqBigNumber(depositMaxTotal.sub(relayed.charge));
    });
  });
});

describe('expected relayable txs', () => {
  let fundOwner: SignerWithAddress;
  let denominationAsset: ITestStandardToken, weth: ITestStandardToken;
  let comptrollerProxy: ComptrollerLib, vaultProxy: VaultLib;
  let gasRelayPaymaster: GasRelayPaymasterLib;
  let relayHub: string, relayWorker: string;

  beforeEach(async () => {
    [fundOwner] = fork.accounts;

    denominationAsset = new ITestStandardToken(fork.config.primitives.usdc, provider);
    weth = new ITestStandardToken(fork.config.weth, provider);

    // relay args
    relayHub = fork.config.gsn.relayHub;
    relayWorker = fork.config.gsn.relayWorker;

    const newFundRes = await createNewFund({
      denominationAsset,
      fundDeployer: fork.deployment.fundDeployer,
      fundOwner,
      signer: fundOwner,
    });

    comptrollerProxy = newFundRes.comptrollerProxy;
    vaultProxy = newFundRes.vaultProxy;

    // Seed the fund with some WETH
    const wethUnit = await getAssetUnit(weth);

    await addNewAssetsToFund({
      provider,
      amounts: [wethUnit.mul(10)],
      assets: [weth],
      comptrollerProxy,
      integrationManager: fork.deployment.integrationManager,
      signer: fundOwner,
    });

    // / set-up paymaster
    await comptrollerProxy.deployGasRelayPaymaster();
    gasRelayPaymaster = new GasRelayPaymasterLib(await comptrollerProxy.getGasRelayPaymaster(), provider);
  });

  describe('ComptrollerLib', () => {
    it('does not allow an unauthorized function', async () => {
      const sendFunction = await buySharesFunction({
        buyer: fundOwner,
        comptrollerProxy,
        denominationAsset,
        provider,
        seedBuyer: true,
      });

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertPaymasterDidRejectForReason(receipt, 'preRelayedCall: Function call not permitted');
    });

    it('happy path: buyBackProtocolFeeShares', async () => {
      const protocolFeeReserveProxy = fork.deployment.protocolFeeReserveProxy;

      denominationAsset = new ITestStandardToken(fork.config.primitives.usdc, provider);
      const mln = new ITestStandardToken(fork.config.primitives.mln, provider);

      const newFundRes = await createNewFund({
        denominationAsset,
        fundDeployer: fork.deployment.fundDeployer,
        fundOwner,
        // Invest the 1st time to give a positive supply of shares and allow accruing protocol fee
        investment: {
          buyer: fundOwner,
          investmentAmount: await getAssetUnit(denominationAsset),
          seedBuyer: true,
          provider,
        },

        signer: fundOwner,
      });

      comptrollerProxy = newFundRes.comptrollerProxy;
      vaultProxy = newFundRes.vaultProxy; // Seed the fund with some WETH
      const wethUnit = await getAssetUnit(weth);

      await addNewAssetsToFund({
        provider,
        amounts: [wethUnit],
        assets: [weth],
        comptrollerProxy,
        integrationManager: fork.deployment.integrationManager,
        signer: fundOwner,
      });

      // / set-up paymaster
      await comptrollerProxy.deployGasRelayPaymaster();
      gasRelayPaymaster = new GasRelayPaymasterLib(await comptrollerProxy.getGasRelayPaymaster(), provider);

      // Warp time to accrue protocol fee, then pay the protocol fee to issue shares to the ProtocolFeeReserveProxy

      const halfYearInSeconds = ONE_YEAR_IN_SECONDS / 2;

      await provider.send('evm_increaseTime', [halfYearInSeconds]);

      // Redeem some shares to pay out the protocol fee
      await redeemSharesInKind({
        comptrollerProxy,
        quantity: (await vaultProxy.balanceOf(fundOwner)).div(2),
        signer: fundOwner,
      });

      const feeSharesCollected = await vaultProxy.balanceOf(protocolFeeReserveProxy);

      expect(feeSharesCollected).toBeGtBigNumber(0);

      // Seed the fund with more MLN than needed to buyback the target shares
      // 1 MLN : 1 USDC is more than enough
      await addNewAssetsToFund({
        provider,
        amounts: [await getAssetUnit(mln)],
        assets: [mln],
        comptrollerProxy,
        integrationManager: fork.deployment.integrationManager,
        signer: fundOwner,
      });

      const preTxGav = await comptrollerProxy.calcGav.call();
      const preTxSharesSupply = await vaultProxy.totalSupply();

      const valueInterpreter = fork.deployment.valueInterpreter;

      const sharesToBuyBack = feeSharesCollected;

      const preTxVaultMlnBalance = await mln.balanceOf(vaultProxy);

      const sendFunction = comptrollerProxy.buyBackProtocolFeeShares.args(sharesToBuyBack);

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(receipt);

      const { mlnValue, mlnAmountToBurn } = await calcMlnValueAndBurnAmountForSharesBuyback({
        buybackSharesAmount: sharesToBuyBack,
        denominationAsset,
        gav: preTxGav,
        mln,
        sharesSupply: preTxSharesSupply,
        valueInterpreter,
      });

      expect(mlnValue).toBeGtBigNumber(0);

      // Assert that the correct amount of MLN was burned
      expect(await mln.balanceOf(vaultProxy)).toEqBigNumber(preTxVaultMlnBalance.sub(mlnAmountToBurn));

      // Assert that all shares of the ProtocolFeeReserveProxy were burned
      expect(await vaultProxy.balanceOf(protocolFeeReserveProxy)).toEqBigNumber(0);
    });

    it('happy path: callOnExtension', async () => {
      const assetToTrack = fork.config.primitives.usdt;

      // Asset should be untracked
      expect(await vaultProxy.isTrackedAsset(assetToTrack)).toBe(false);

      const sendFunction = comptrollerProxy.callOnExtension.args(
        fork.deployment.integrationManager.address,
        IntegrationManagerActionId.AddTrackedAssetsToVault,
        addTrackedAssetsToVaultArgs({ assets: [fork.config.primitives.usdt] }),
      );

      await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      // Asset should now be tracked
      expect(await vaultProxy.isTrackedAsset(assetToTrack)).toBe(true);
    });

    it('happy path: depositToGasRelayPaymaster', async () => {
      const sendFunction = comptrollerProxy.depositToGasRelayPaymaster.args();

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(receipt);
    });

    it('happy path: setAutoProtocolFeeSharesBuyback', async () => {
      // autoProtocolFeeSharesBuyback should be off
      expect(await comptrollerProxy.doesAutoProtocolFeeSharesBuyback()).toBe(false);

      const sendFunction = comptrollerProxy.setAutoProtocolFeeSharesBuyback.args(true);

      await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      // autoProtocolFeeSharesBuyback should be on
      expect(await comptrollerProxy.doesAutoProtocolFeeSharesBuyback()).toBe(true);
    });

    it('happy path: vaultCallOnContract', async () => {
      // Register a call for a token approval to a specific address
      const contract = weth;
      const asset = weth;
      const functionSighash = sighash(utils.FunctionFragment.fromString('approve(address,uint256)'));
      const spender = randomAddress();
      const validEncodedArgs = encodeArgs(['address', 'uint'], [spender, constants.MaxUint256]);

      const fundDeployer = fork.deployment.fundDeployer;

      await fundDeployer.registerVaultCalls([weth], [functionSighash], [utils.keccak256(validEncodedArgs)]);

      // The registered call with valid encoded args should succeed
      const sendFunction = comptrollerProxy.vaultCallOnContract.args(
        contract,
        functionSighash,
        encodeArgs(['address', 'uint'], [spender, constants.MaxUint256]),
      );

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(receipt);
      expect(await asset.allowance(vaultProxy, spender)).toEqBigNumber(constants.MaxUint256);
    });
  });

  describe('FundDeployer', () => {
    let fundDeployer: FundDeployer;

    beforeEach(async () => {
      fundDeployer = fork.deployment.fundDeployer;
    });

    it('does not allow payment of calls to unauthorized vaults', async () => {
      const newFund = await createNewFund({
        denominationAsset,
        fundDeployer: fork.deployment.fundDeployer,
        fundOwner,
        signer: fundOwner,
      });
      const wethUnit = await getAssetUnit(weth);

      await addNewAssetsToFund({
        provider,
        amounts: [wethUnit],
        assets: [weth],
        comptrollerProxy: newFund.comptrollerProxy,
        integrationManager: fork.deployment.integrationManager,
        signer: fundOwner,
      });
      await newFund.comptrollerProxy.deployGasRelayPaymaster();

      const sendFunction = fundDeployer
        .connect(fundOwner)
        .createReconfigurationRequest.args(newFund.vaultProxy, denominationAsset, 0, '0x', '0x');

      // note vaultPaymaster here is the paymaster on "old" fund
      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertPaymasterDidRejectForReason(receipt, 'preRelayedCall: Function call not permitted');

      // There should now be a pending reconfiguration request for the VaultProxy
      expect(await fundDeployer.hasReconfigurationRequest(newFund.vaultProxy)).toBe(false);
    });

    it('happy path: createReconfigurationRequest', async () => {
      const sendFunction = fundDeployer
        .connect(fundOwner)
        .createReconfigurationRequest.args(vaultProxy, denominationAsset, 0, '0x', '0x');

      await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      // There should now be a pending reconfiguration request for the VaultProxy
      expect(await fundDeployer.hasReconfigurationRequest(vaultProxy)).toBe(true);
    });

    it('happy path: executeReconfiguration', async () => {
      await fundDeployer.connect(fundOwner).createReconfigurationRequest(vaultProxy, denominationAsset, 0, '0x', '0x');
      const reconfigurationTimelock = await fundDeployer.getReconfigurationTimelock();

      await provider.send('evm_increaseTime', [reconfigurationTimelock.toNumber()]);

      const sendFunction = fundDeployer.connect(fundOwner).executeReconfiguration.args(vaultProxy);

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(receipt);
    });

    it('happy path: cancelReconfiguration', async () => {
      await fundDeployer.connect(fundOwner).createReconfigurationRequest(vaultProxy, denominationAsset, 0, '0x', '0x');
      expect(await fundDeployer.hasReconfigurationRequest(vaultProxy)).toBe(true);

      const sendFunction = fundDeployer.connect(fundOwner).cancelReconfiguration.args(vaultProxy);

      await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      // There should now be a pending reconfiguration request for the VaultProxy
      expect(await fundDeployer.hasReconfigurationRequest(vaultProxy)).toBe(false);
    });
  });
  describe('PolicyManager', () => {
    let policyManager: PolicyManager;
    let allowedDepositRecipientsPolicy: AllowedDepositRecipientsPolicy;

    beforeEach(async () => {
      policyManager = fork.deployment.policyManager;
      allowedDepositRecipientsPolicy = fork.deployment.allowedDepositRecipientsPolicy;
    });

    it('does not allow an unauthorized function', async () => {
      const newFund = await createNewFund({
        denominationAsset,
        fundDeployer: fork.deployment.fundDeployer,
        fundOwner,
        signer: fundOwner,
      });
      const wethUnit = await getAssetUnit(weth);

      await addNewAssetsToFund({
        provider,
        amounts: [wethUnit],
        assets: [weth],
        comptrollerProxy: newFund.comptrollerProxy,
        integrationManager: fork.deployment.integrationManager,
        signer: fundOwner,
      });
      await newFund.comptrollerProxy.deployGasRelayPaymaster();
      const sendFunction = policyManager.connect(fundOwner).enablePolicyForFund.args(
        newFund.comptrollerProxy,
        allowedDepositRecipientsPolicy,
        addressListRegistryPolicyArgs({
          newListsArgs: [{ initialItems: [randomAddress()], updateType: AddressListUpdateType.None }],
        }),
      );

      // Note this is the paymaster of the "old" fund
      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertPaymasterDidRejectForReason(receipt, 'preRelayedCall: Function call not permitted');
      // Policy should be added
      expect(await policyManager.getEnabledPoliciesForFund(comptrollerProxy)).toMatchFunctionOutput(
        policyManager.getEnabledPoliciesForFund,
        [],
      );
    });

    it('happy path: enablePolicyForFund', async () => {
      const sendFunction = policyManager.connect(fundOwner).enablePolicyForFund.args(
        comptrollerProxy,
        allowedDepositRecipientsPolicy,
        addressListRegistryPolicyArgs({
          newListsArgs: [{ initialItems: [randomAddress()], updateType: AddressListUpdateType.None }],
        }),
      );

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(receipt);
      // Policy should be added
      expect(await policyManager.getEnabledPoliciesForFund(comptrollerProxy)).toMatchFunctionOutput(
        policyManager.getEnabledPoliciesForFund,
        [allowedDepositRecipientsPolicy],
      );
    });

    it('happy path: updatePolicySettingsForFund', async () => {
      // add policy to fund
      await policyManager.connect(fundOwner).enablePolicyForFund(
        comptrollerProxy,
        allowedDepositRecipientsPolicy,
        addressListRegistryPolicyArgs({
          newListsArgs: [{ initialItems: [randomAddress()], updateType: AddressListUpdateType.None }],
        }),
      );
      expect(await policyManager.getEnabledPoliciesForFund(comptrollerProxy)).toMatchFunctionOutput(
        policyManager.getEnabledPoliciesForFund,
        [allowedDepositRecipientsPolicy],
      );

      const newInvestor = randomAddress();

      // Investor should not yet be in list
      expect(await allowedDepositRecipientsPolicy.passesRule(comptrollerProxy, newInvestor)).toBe(false);

      const sendFunction = policyManager.connect(fundOwner).updatePolicySettingsForFund.args(
        comptrollerProxy,
        allowedDepositRecipientsPolicy,
        addressListRegistryPolicyArgs({
          newListsArgs: [{ initialItems: [newInvestor], updateType: AddressListUpdateType.None }],
        }),
      );

      await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      // Investor should now be added to list
      expect(await allowedDepositRecipientsPolicy.passesRule(comptrollerProxy, newInvestor)).toBe(true);
    });

    it('happy path: disablePolicyForFund', async () => {
      await policyManager.connect(fundOwner).enablePolicyForFund(
        comptrollerProxy,
        allowedDepositRecipientsPolicy,
        addressListRegistryPolicyArgs({
          newListsArgs: [{ initialItems: [randomAddress()], updateType: AddressListUpdateType.None }],
        }),
      );
      const sendFunction = policyManager
        .connect(fundOwner)
        .disablePolicyForFund.args(comptrollerProxy, allowedDepositRecipientsPolicy);

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(receipt);
      expect(await policyManager.getEnabledPoliciesForFund(comptrollerProxy)).toMatchFunctionOutput(
        policyManager.getEnabledPoliciesForFund,
        [],
      );
    });
  });

  describe('VaultLib', () => {
    // Only test 1 path, specific allowed paths are not defined

    it('happy path: addAssetManagers', async () => {
      const assetManagerToAdd = randomAddress();

      // Account should not yet be an asset manager
      expect(await vaultProxy.isAssetManager(assetManagerToAdd)).toBe(false);

      const sendFunction = vaultProxy.addAssetManagers.args([assetManagerToAdd]).from(fundOwner);

      await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      // Account should now be an asset manager
      expect(await vaultProxy.isAssetManager(assetManagerToAdd)).toBe(true);
    });
  });

  describe('Lifecycle', () => {
    let fundDeployer: FundDeployer;

    beforeEach(async () => {
      fundDeployer = fork.deployment.fundDeployer;
    });

    it('happy path: should withdraw gas relay deposit on migration', async () => {
      const nextFundDeployer = await createFundDeployer({
        deployer: fundOwner,
        dispatcher: fork.deployment.dispatcher,
        externalPositionManager: fork.deployment.externalPositionManager,
        feeManager: fork.deployment.feeManager,
        gasRelayPaymasterFactory: fork.deployment.gasRelayPaymasterFactory,
        integrationManager: fork.deployment.integrationManager,
        policyManager: fork.deployment.policyManager,
        setOnDispatcher: true,
        setReleaseLive: true,
        valueInterpreter: fork.deployment.valueInterpreter,
        vaultLib: fork.deployment.vaultLib,
      });

      const [preMigrationWethBalance] = await getAssetBalances({
        account: vaultProxy,
        assets: [weth],
      });

      await createMigrationRequest({
        denominationAsset: weth,
        fundDeployer: nextFundDeployer,
        signer: fundOwner,
        vaultProxy,
      });

      // Warp to migration executable time
      const migrationTimelock = await fork.deployment.dispatcher.connect(fundOwner).getMigrationTimelock();

      await provider.send('evm_increaseTime', [migrationTimelock.toNumber()]);
      await nextFundDeployer.connect(fundOwner).executeMigration(vaultProxy, false);

      const rHContract = new ITestGsnRelayHub(relayHub, fundOwner);
      const deposit = await rHContract.balanceOf(gasRelayPaymaster.address);

      await gasRelayPaymaster.connect(fundOwner).withdrawBalance();
      const [postMigrationWethBalance] = await getAssetBalances({
        account: vaultProxy,
        assets: [weth],
      });

      expect(postMigrationWethBalance.sub(preMigrationWethBalance)).toEqBigNumber(deposit);
    });

    it('should be able to relay after reconfiguration', async () => {
      await fundDeployer.connect(fundOwner).createReconfigurationRequest(vaultProxy, denominationAsset, 0, '0x', '0x');
      const reconfigurationTimelock = await fundDeployer.getReconfigurationTimelock();

      await provider.send('evm_increaseTime', [reconfigurationTimelock.toNumber()]);

      const reconfig = fundDeployer.connect(fundOwner).executeReconfiguration.args(vaultProxy);

      const receipt = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction: reconfig,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(receipt);

      const assetToTrack = fork.config.primitives.usdt;

      // Asset should be untracked
      expect(await vaultProxy.isTrackedAsset(assetToTrack)).toBe(false);

      const newComptrollerAddress = await vaultProxy.getAccessor();
      const newComptroller = new ComptrollerLib(newComptrollerAddress, fundOwner);

      const sendFunction = newComptroller.callOnExtension.args(
        fork.deployment.integrationManager.address,
        IntegrationManagerActionId.AddTrackedAssetsToVault,
        addTrackedAssetsToVaultArgs({ assets: [fork.config.primitives.usdt] }),
      );

      const result = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(result);

      // Asset should now be tracked
      expect(await vaultProxy.isTrackedAsset(assetToTrack)).toBe(true);
    });

    it('should be able to shutdown gas relayer', async () => {
      let sendFunction = comptrollerProxy.setAutoProtocolFeeSharesBuyback.args(true);
      const result = await relayTransaction({
        relayHub,
        relayWorker,
        sendFunction,
        vaultPaymaster: gasRelayPaymaster.address,
      });

      assertDidRelaySuccessfully(result);

      await comptrollerProxy.shutdownGasRelayPaymaster();

      // shouldn't be able to relay anymore
      sendFunction = comptrollerProxy.setAutoProtocolFeeSharesBuyback.args(false);
      await expect(
        relayTransaction({
          relayHub,
          relayWorker,
          sendFunction,
          vaultPaymaster: gasRelayPaymaster.address,
        }),
      ).rejects.toBeRevertedWith('Paymaster balance too low');
      const rHContract = new ITestGsnRelayHub(relayHub, fundOwner);

      expect(await rHContract.balanceOf(gasRelayPaymaster.address)).toEqBigNumber(0);
    });
  });
});