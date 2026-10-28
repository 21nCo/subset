import Foundation
import SystemHelper

// subset-system: the read-only agent helper. It reads processes and memory and prints them; it never
// changes, deletes, or sends anything.
let output = await HelperRunner.run(Array(CommandLine.arguments.dropFirst()), environment: .live())
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.exit.rawValue)
