const { createApp } = require("./server");

const port = process.env.PORT || 8080;

createApp().listen(port, () => {
  console.log(`patient-portal-service listening on port ${port}`);
});
