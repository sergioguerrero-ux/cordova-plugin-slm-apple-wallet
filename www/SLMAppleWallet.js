var exec = require('cordova/exec');

module.exports = {
  canAddPaymentPass: function () {
    return new Promise(function (resolve, reject) {
      exec(resolve, reject, 'SLMAppleWallet', 'canAddPaymentPass', []);
    });
  },

  // En el siguiente paso implementamos el flujo real
  startAddPaymentPass: function (options) {
    return new Promise(function (resolve, reject) {
      exec(resolve, reject, 'SLMAppleWallet', 'startAddPaymentPass', [options || {}]);
    });
  }
};
