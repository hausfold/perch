import Foundation

// `perch` is a thin sender: it copies bytes into the App Group mailbox and lets
// the running app admit, adopt, and display them. All of the interesting logic
// lives in PerchTool; this file exists to
// keep the process's exit status the only thing top-level code decides.
exit(PerchTool(arguments: Array(CommandLine.arguments.dropFirst())).run().rawValue)
