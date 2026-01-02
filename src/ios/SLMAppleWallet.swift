import Foundation
import PassKit

@objc(SLMAppleWallet)
class SLMAppleWallet: CDVPlugin, PKAddPaymentPassViewControllerDelegate {

    struct Session {
        let sessionId: String
        let callbackId: String
        let options: [String: Any]
        var completionHandler: ((PKAddPaymentPassRequest) -> Void)?
    }

    private var sessions: [String: Session] = [:]
    private var activeSessionId: String?

    // MARK: - Helpers

    private func b64(_ data: Data) -> String { data.base64EncodedString() }

    private func dataFromB64(_ s: String) -> Data? { Data(base64Encoded: s) }

    private func json(_ obj: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj, options: [])
    }

    private func debugLog(_ opts: [String: Any], _ msg: String) {
        if (opts["debug"] as? Bool) == true {
            NSLog("[SLMAppleWallet] \(msg)")
        }
    }

    private func getEncryptionScheme(_ opts: [String: Any]) -> PKEncryptionScheme {
        let scheme = (opts["encryptionScheme"] as? String)?.uppercased() ?? "ECC_V2"
        switch scheme {
        case "RSA_V2": return .RSA_V2
        default: return .ECC_V2
        }
    }

    private func getString(_ opts: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let v = opts[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    private func sendOK(_ callbackId: String, _ payload: [String: Any]) {
        let pr = CDVPluginResult(status: .ok, messageAs: payload)
        self.commandDelegate.send(pr, callbackId: callbackId)
    }

    private func sendERR(_ callbackId: String, _ message: String, extra: [String: Any] = [:]) {
        var p: [String: Any] = ["ok": false, "error": message]
        extra.forEach { p[$0.key] = $0.value }
        let pr = CDVPluginResult(status: .ok, messageAs: p)
        self.commandDelegate.send(pr, callbackId: callbackId)
    }

    // MARK: - Public API

    @objc(canAddPaymentPass:)
    func canAddPaymentPass(command: CDVInvokedUrlCommand) {
        let canAdd = PKAddPaymentPassViewController.canAddPaymentPass()
        var res: [String: Any] = [
            "ok": true,
            "canAdd": canAdd,
            "iosVersion": UIDevice.current.systemVersion
        ]
        if !canAdd { res["reason"] = "unavailable_or_missing_entitlement" }
        sendOK(command.callbackId, res)
    }

    // MODO A (recomendado): si options.backendUrl existe, el plugin hace el roundtrip a tu backend.
    // MODO B: si no hay backendUrl, el plugin devuelve challenge y esperará completeAddPaymentPass()
    @objc(startAddPaymentPass:)
    func startAddPaymentPass(command: CDVInvokedUrlCommand) {
        guard let opts = (command.arguments.first as? [String: Any]) else {
            return sendERR(command.callbackId, "invalid_options")
        }

        if !PKAddPaymentPassViewController.canAddPaymentPass() {
            return sendERR(command.callbackId, "cannot_add_payment_pass", extra: ["reason": "unavailable_or_missing_entitlement"])
        }

        let sessionId = UUID().uuidString
        let scheme = getEncryptionScheme(opts)

        let holder = getString(opts, ["cardholderName","holderName","holder"]) ?? ""
        let suffix = getString(opts, ["suffix","last4"]) ?? ""
        let desc = getString(opts, ["localizedDescription","description"]) ?? "Payment Card"

        guard let cfg = PKAddPaymentPassRequestConfiguration(encryptionScheme: scheme) else {
            return sendERR(command.callbackId, "cannot_create_request_configuration")
        }

        cfg.cardholderName = holder
        cfg.primaryAccountSuffix = suffix
        cfg.localizedDescription = desc

        var session = Session(sessionId: sessionId, callbackId: command.callbackId, options: opts, completionHandler: nil)
        sessions[sessionId] = session
        activeSessionId = sessionId

        debugLog(opts, "Starting add payment pass. sessionId=\(sessionId) scheme=\(scheme) suffix=\(suffix)")

        DispatchQueue.main.async {
            guard let vc = PKAddPaymentPassViewController(requestConfiguration: cfg, delegate: self) else {
                self.sendERR(command.callbackId, "pkaddpaymentpassviewcontroller_nil", extra: ["sessionId": sessionId])
                self.sessions.removeValue(forKey: sessionId)
                self.activeSessionId = nil
                return
            }
            self.viewController.present(vc, animated: true)

            // devolvemos inmediato para que tu web sepa que ya se presentó
            self.sendOK(command.callbackId, [
                "ok": true,
                "sessionId": sessionId,
                "status": "presented",
                "mode": (opts["backendUrl"] as? String)?.isEmpty == false ? "A" : "B"
            ])
        }
    }

    // MODO B: tu web/backend te devuelve activationData/encryptedPassData/ephemeralPublicKey y tú completas
    @objc(completeAddPaymentPass:)
    func completeAddPaymentPass(command: CDVInvokedUrlCommand) {
        guard let opts = (command.arguments.first as? [String: Any]) else {
            return sendERR(command.callbackId, "invalid_options")
        }
        guard let sessionId = opts["sessionId"] as? String,
              var session = sessions[sessionId] else {
            return sendERR(command.callbackId, "invalid_session")
        }
        guard let ch = session.completionHandler else {
            return sendERR(command.callbackId, "no_pending_completion_handler", extra: ["sessionId": sessionId])
        }

        guard let activationB64 = opts["activationData"] as? String,
              let encryptedB64 = opts["encryptedPassData"] as? String,
              let ephB64 = opts["ephemeralPublicKey"] as? String,
              let activation = dataFromB64(activationB64),
              let encrypted = dataFromB64(encryptedB64),
              let eph = dataFromB64(ephB64) else {
            return sendERR(command.callbackId, "invalid_backend_payload", extra: ["sessionId": sessionId])
        }

        let req = PKAddPaymentPassRequest()
        req.activationData = activation
        req.encryptedPassData = encrypted
        req.ephemeralPublicKey = eph

        debugLog(session.options, "Completing request for sessionId=\(sessionId)")

        ch(req)
        session.completionHandler = nil
        sessions[sessionId] = session

        sendOK(command.callbackId, ["ok": true, "sessionId": sessionId, "status": "completed_request_sent"])
    }

    // MARK: - PKAddPaymentPassViewControllerDelegate

    func addPaymentPassViewController(_ controller: PKAddPaymentPassViewController,
                                      generateRequestWithCertificateChain certificates: [Data],
                                      nonce: Data,
                                      nonceSignature: Data,
                                      completionHandler handler: @escaping (PKAddPaymentPassRequest) -> Void) {

        guard let sessionId = activeSessionId,
              var session = sessions[sessionId] else {
            controller.dismiss(animated: true)
            return
        }

        session.completionHandler = handler
        sessions[sessionId] = session

        let certsB64 = certificates.map { b64($0) }
        let nonceB64 = b64(nonce)
        let sigB64 = b64(nonceSignature)

        let device: [String: Any] = [
            "iosVersion": UIDevice.current.systemVersion,
            "model": UIDevice.current.model
        ]

        let payload: [String: Any] = [
            "sessionId": sessionId,
            "cardId": session.options["cardId"] ?? NSNull(),
            "holderName": session.options["holderName"] ?? session.options["cardholderName"] ?? NSNull(),
            "last4": session.options["last4"] ?? session.options["suffix"] ?? NSNull(),
            "certificates": certsB64,
            "nonce": nonceB64,
            "nonceSignature": sigB64,
            "device": device
        ]

        debugLog(session.options, "Got challenge (certs/nonce). sessionId=\(sessionId) certs=\(certificates.count)")

        // MODO A: si hay backendUrl, el plugin llama a tu backend y completa SOLO.
        if let backendUrl = session.options["backendUrl"] as? String, !backendUrl.isEmpty {
            callBackendAndComplete(session: session, payload: payload, backendUrl: backendUrl)
        } else {
            // MODO B: tú lo mandas desde web. Aquí no podemos resolver tu Promise viejo otra vez,
            // así que lo ideal es que tu web llame a slmwafk.appleWalletCompleteAdd({...}) con sessionId y respuesta del backend.
            // Te dejamos el payload accesible por consola o si quieres lo enviamos a tu web por un "event" (puedo agregártelo si lo quieres).
            debugLog(session.options, "Mode B: waiting for web to call completeAddPaymentPass(sessionId, activationData, encryptedPassData, ephemeralPublicKey)")
        }
    }

    func addPaymentPassViewController(_ controller: PKAddPaymentPassViewController,
                                      didFinishAdding pass: PKPaymentPass?,
                                      error: Error?) {

        guard let sessionId = activeSessionId,
              let session = sessions[sessionId] else {
            controller.dismiss(animated: true)
            return
        }

        let opts = session.options
        debugLog(opts, "Finished adding. sessionId=\(sessionId) pass=\(pass != nil) error=\(String(describing: error))")

        controller.dismiss(animated: true)

        var result: [String: Any] = [
            "ok": (error == nil),
            "sessionId": sessionId,
            "status": (error == nil) ? "added" : "failed"
        ]

        if let e = error {
            result["error"] = e.localizedDescription
        }

        // Limpieza
        sessions.removeValue(forKey: sessionId)
        activeSessionId = nil

        // Nota: startAddPaymentPass ya resolvió un OK "presented".
        // Para comunicar el final a tu web, lo más robusto es disparar un evento JS global.
        // (Te lo dejo abajo como opcional para que sea "muy completo".)
        fireJsEvent(name: "slm.appleWallet.finished", detail: result)
    }

    // MARK: - Backend call (Mode A)

    private func callBackendAndComplete(session: Session, payload: [String: Any], backendUrl: String) {
        guard let url = URL(string: backendUrl) else {
            sendERR(session.callbackId, "invalid_backend_url", extra: ["sessionId": session.sessionId])
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let headers = session.options["backendHeaders"] as? [String: String] {
            for (k,v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }

        let timeout = (session.options["backendTimeoutMs"] as? Double ?? 25000) / 1000.0
        req.timeoutInterval = timeout

        req.httpBody = json(payload)

        debugLog(session.options, "Calling backend \(backendUrl) sessionId=\(session.sessionId)")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                self.debugLog(session.options, "Backend error: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let activationB64 = obj["activationData"] as? String,
                  let encryptedB64 = obj["encryptedPassData"] as? String,
                  let ephB64 = obj["ephemeralPublicKey"] as? String,
                  let activation = self.dataFromB64(activationB64),
                  let encrypted = self.dataFromB64(encryptedB64),
                  let eph = self.dataFromB64(ephB64) else {
                self.debugLog(session.options, "Invalid backend response")
                return
            }

            guard var s = self.sessions[session.sessionId],
                  let ch = s.completionHandler else {
                self.debugLog(session.options, "No pending completion handler")
                return
            }

            let addReq = PKAddPaymentPassRequest()
            addReq.activationData = activation
            addReq.encryptedPassData = encrypted
            addReq.ephemeralPublicKey = eph

            self.debugLog(session.options, "Completing PassKit request (Mode A) sessionId=\(session.sessionId)")
            ch(addReq)

            s.completionHandler = nil
            self.sessions[session.sessionId] = s
        }.resume()
    }

    // MARK: - JS event bridge (optional but very useful)

    private func fireJsEvent(name: String, detail: [String: Any]) {
        if let jsonData = try? JSONSerialization.data(withJSONObject: detail, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8) {

            let js = """
            window.dispatchEvent(new CustomEvent('\(name)', { detail: \(jsonStr) }));
            """

            DispatchQueue.main.async {
                self.commandDelegate.evalJs(js)
            }
        }
    }
}
