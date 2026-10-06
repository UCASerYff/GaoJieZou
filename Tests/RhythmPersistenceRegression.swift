import Foundation
enum RhythmBundle { static let bundle=Bundle.main }
// The persistence component consumes only this error from the store.
enum RhythmStoreError: Error { case backupFromNewerVersion(found: Int) }
@main struct RhythmPersistenceRegression {
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("gq-rhythm-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? fm.removeItem(at:root) }
  setenv("GAOJIEZOU_DATA_DIR",root.path,1)
  let file=root.appendingPathComponent("library.json"),original=Data("{broken data".utf8)
  try original.write(to:file)
  let first=RhythmPersistence()
  guard case .corrupted = first.load() else { fatalError("corruption accepted") }
  let preserved=try Data(contentsOf:file);assert(preserved==original)
  // A later launch must remain protected even if the damaged file is moved externally.
  try fm.removeItem(at:file)
  guard case .corrupted = RhythmPersistence().load() else { fatalError("lost persistent lockout") }
  try first.write(.starter());try first.clearFailureMarker()
  guard case .loaded = RhythmPersistence().load() else { fatalError("valid restore failed") }
  var future=RhythmLibrary.starter();future.version=RhythmEconomy.schemaVersion+1
  try first.write(future)
  guard case .corrupted = RhythmPersistence().load() else { fatalError("newer schema accepted") }
  let saved=try JSONDecoder().decode(RhythmLibrary.self,from:Data(contentsOf:file));assert(saved.version==future.version)
  print("PASS Rhythm persistence: corrupt file retained; protection survives relaunch and missing file; verified restore clears protection; newer schema preserved")
 }
}
