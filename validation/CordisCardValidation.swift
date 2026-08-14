import Foundation

@main
struct CordisCardValidation {
    static func main() {
        validateCardModels()
        print("CordisCardValidation: 6 fixtures passed")
    }

    private static func validateCardModels() {
        let args = #"{"name":"Clock","purpose":"show time","code":{"host":"HOST_CODE","client":"CLIENT_CODE"}}"#
        guard case let .define(running)? = CordisCardModel.make(name: "cordis_define", callId: "call-1",
            argsRaw: args, output: nil, resultMeta: nil, resultSeq: nil, state: .running) else { fail("running define") }
        expect(running.name == "Clock" && running.purpose == "show time", "define labels")
        expect(running.hostCode == "HOST_CODE" && running.clientCode == "CLIENT_CODE", "symmetric source")
        expect(running.pluginId == nil && running.packageId == nil, "unsettled identity")

        guard case let .define(settled)? = CordisCardModel.make(name: "cordis_define", callId: "call-1",
            argsRaw: args, output: "defined", resultMeta: ["pluginId": "clock-1", "packageId": "pkg-1"],
            resultSeq: 9, state: .ok) else { fail("settled define") }
        expect(settled.pluginId == "clock-1" && settled.packageId == "pkg-1", "define meta")

        guard case let .run(run)? = CordisCardModel.make(name: "cordis_run", callId: "call-2",
            argsRaw: #"{"pluginId":"clock-1","packageId":"pkg-1","mode":"update"}"#,
            output: "running", resultMeta: ["pluginId": "clock-1", "packageId": "pkg-1", "pluginRunId": "run-1"],
            resultSeq: 12, state: .ok) else { fail("run") }
        expect(run.pluginRunId == "run-1" && run.mode == "update" && run.seq == 12, "run meta")

        guard case let .action(action)? = CordisCardModel.make(name: "cordis_stop", callId: "call-3",
            argsRaw: #"{"pluginId":"clock-1"}"#, output: "Stopped clock-1.", resultMeta: nil,
            resultSeq: 14, state: .ok) else { fail("action") }
        expect(action.pluginId == "clock-1" && action.output == "Stopped clock-1.", "action identity")

        guard case let .define(failed)? = CordisCardModel.make(name: "cordis_define", callId: "call-4",
            argsRaw: args, output: "SyntaxError: bad\nline 2", resultMeta: ["pluginId": "must-ignore"],
            resultSeq: 15, state: .error) else { fail("failed define") }
        expect(failed.pluginId == nil && failed.errorSummary == "SyntaxError: bad", "error meta guard")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() { fail(label) }
    }
    private static func fail(_ label: String) -> Never {
        fputs("CordisCardValidation failed: \(label)\n", stderr)
        exit(1)
    }
}
