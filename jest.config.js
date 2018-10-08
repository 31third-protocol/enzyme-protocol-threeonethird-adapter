module.exports = {
  transform: {
    "^.+\\.tsx?$": "ts-jest"
  },
  testRegex: "((\\.|/)(test|spec))\\.(jsx?|tsx?)$",
  moduleFileExtensions: ["ts", "tsx", "js", "jsx", "json", "node", "bin"],
  globalSetup: "./tests/setup.js",
  moduleNameMapper: {
    "~/(.*)": "<rootDir>/ref/$1"
  }
};
