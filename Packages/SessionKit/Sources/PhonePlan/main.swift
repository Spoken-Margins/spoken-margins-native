import Foundation
import SessionKit

do {
    let request = try JSONDecoder().decode(PhoneValidationPlan.Request.self,
                                          from: FileHandle.standardInput.readDataToEndOfFile())
    let plan = try PhoneValidationPlan.audit(request)
    struct Output: Encodable { var markdown: String; var minutes: Int }
    let output = Output(markdown: plan.markdown(build: request.build, planID: CommandLine.arguments[1]),
                        minutes: plan.minutes)
    FileHandle.standardOutput.write(try JSONEncoder().encode(output))
} catch {
    FileHandle.standardError.write(Data("Invalid phone plan: \(error)\n".utf8))
    exit(1)
}
