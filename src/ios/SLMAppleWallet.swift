import Foundation
import PassKit

@objc(SLMAppleWallet)
class SLMAppleWallet: CDVPlugin {

    @objc(canAddPaymentPass:)
    func canAddPaymentPass(command: CDVInvokedUrlCommand) {
        let canAdd = PKAddPaymentPassViewController.canAddPaymentPass()

        var result: [String: Any] = [
            "ok": true,
            "canAdd": canAdd,
            "iosVersion": UIDevice.current.systemVersion
        ]

        if !canAdd {
            // Apple no da causa exacta aquí.
            // Suele ser: dispositivo no soporta / Apple Pay desactivado / falta entitlement issuer.
            result["reason"] = "unavailable_or_missing_entitlement"
        }

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: result)
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }

    @objc(startAddPaymentPass:)
    func startAddPaymentPass(command: CDVInvokedUrlCommand) {
        let result: [String: Any] = [
            "ok": false,
            "error": "not_implemented_yet",
            "hint": "Next step: implement PKAddPaymentPassViewController + backend roundtrip to Pomelo"
        ]

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: result)
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }
}
