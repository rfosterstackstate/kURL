module.exports = {
  ENVIRONMENT: "development",
  API_ENDPOINT: `https://tgapi-${ process.env.OKTETO_NAMESPACE }.replicated.okteto.dev/api/v1`,
  WEBPACK_SCRIPTS: [
    "https://unpkg.com/react@17/umd/react.development.js",
    "https://unpkg.com/react-dom@17/umd/react-dom.development.js",
  ]
};
