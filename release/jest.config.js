const { whales } = require('./utils/network/config.json');

module.exports = {
  globals: {
    'ts-jest': {
      diagnostics: {
        warnOnly: true,
      },
    },
  },

  projects: [
    {
      displayName: 'ganache',
      preset: '@crestproject/ganache',
      testMatch: ['**/?(*.)+(e2e).[jt]s?(x)'],
      testTimeout: 120000,
      testEnvironmentOptions: {
        ganacheProviderOptions: {
          gasLimit: 0x989680,
          default_balance_ether: 10000000000000,
          fork: 'https://mainnet.infura.io/v3/ffe0be31d7d34594b3decc6c7778e9ad',
          // NOTE: You can unlock arbitrary accounts to gather their tokens into our
          // test accounts and then trade with them for instance.
          unlocked_accounts: Object.values(whales),
          // NOTE: Currently we can only test on the latest block because we do not have
          // a paid account on infura. This is bad because we want our tests to run within
          // a predictable environment so we should definitely set the fork block number.
          // fork_block_number: 12345
        },
      },
    },
    {
      displayName: 'buidler',
      preset: '@crestproject/buidler',
      testEnvironmentOptions: {
        buidlerConfigs: [
          require.resolve('./buidler.config'),
          require.resolve('@melonproject/persistent/buidler.config'),
          require.resolve('@melonproject/utils/buidler.config'),
        ],
      },
    },
  ],
};
