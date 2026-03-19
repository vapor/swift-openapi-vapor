import Vapor

enum CurrentContext {
  @TaskLocal
  static var request: Request? = nil
}
