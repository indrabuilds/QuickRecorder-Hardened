from pathlib import Path
import sys
source = Path("QuickRecorder/ViewModel/StatusBar.swift").read_text()
# The local macOS 27 Command Line Tools omit SwiftUIMacros. Refer to the
# same State property wrapper under an alias for this test-only build.
source = source.replace("import SwiftUI", "import SwiftUI\ntypealias HarnessState<Value> = SwiftUI.State<Value>", 1)
source = source.replace("@State private var", "@HarnessState private var")
Path(sys.argv[1]).write_text(source + "\n" + Path("Tests/StatusBarHarnessStubs.swift").read_text())
