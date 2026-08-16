import Foundation
import FSKit

@main
struct ClaudelessFSExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        ClaudelessFS()
    }
}
