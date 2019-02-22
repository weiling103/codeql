/**
 * Provides a taint tracking configuration for reasoning about unsafe zip extraction.
 */

import javascript

module ZipSlip {
  /**
   * A data flow source for unsafe zip extraction.
   */
  abstract class Source extends DataFlow::Node { }

  /**
   * A data flow sink for unsafe zip extraction.
   */
  abstract class Sink extends DataFlow::Node { }

  /**
   * A sanitizer guard for unsafe zip extraction.
   */
  abstract class SanitizerGuard extends TaintTracking::SanitizerGuardNode, DataFlow::ValueNode { }

  /** A taint tracking configuration for Zip Slip */
  class Configuration extends TaintTracking::Configuration {
    Configuration() { this = "ZipSlip" }

    override predicate isSource(DataFlow::Node source) { source instanceof Source }

    override predicate isSink(DataFlow::Node sink) { sink instanceof Sink }

    override predicate isSanitizerGuard(TaintTracking::SanitizerGuardNode nd) {
      nd instanceof SanitizerGuard
    }
  }

  /**
   * Holds if `node1` flows to `node2` in one step by virtue of
   * `node2` being of the form `.pipe(node1)`. The reason this flow
   * exists is that `.pipe` returns its argument to make chained
   * stream operations work.
   */
  predicate pipeStep(DataFlow::Node node1, DataFlow::MethodCallNode node2) {
      node2.getMethodName() = "pipe" and
      node1 = node2.getArgument(0)
  }

  /**
   * Holds if `node1` flows to `node2` in one step including the assumption that
   * `x` flows to `.pipe(x)`
   */
  predicate stepsThroughPipe(DataFlow::Node node1, DataFlow::Node node2) {
    DataFlow::localFlowStep(node1, node2) or pipeStep(node1, node2)
  }

  /**
   * Holds if `node1` flows to `node2` including the assumption that
   * `x` flows to `.pipe(x)`
   */
  predicate flowsThroughPipe(DataFlow::Node node1, DataFlow::Node node2) {
    stepsThroughPipe*(node1, node2)
  }

  /**
   * An access to the filepath of an entry of a zipfile being extracted
   * by npm module `unzip`. For example, in
   * ```javascript
   * const unzip = require('unzip');
   *
   * fs.createReadStream('archive.zip')
   *   .pipe(unzip.Parse())
   *   .on('entry', entry => {
   *      const path = entry.path;
   *   });
   * ```
   * there is an `UnzipEntrySource` node corresponding to
   * the expression `entry.path`.
   */
  class UnzipEntrySource extends Source {
    UnzipEntrySource() {
      exists(DataFlow::SourceNode parsed |
        flowsThroughPipe(DataFlow::moduleImport("unzip").getAMemberCall("Parse"), parsed)
        and
        this = parsed.getAMemberCall("on").getCallback(1).getParameter(0).getAPropertyRead("path")
      )
    }
  }

  /**
   * A sink that is the path that a createWriteStream gets created at.
   * This is not covered by FileSystemWriteSink, because it is
   * required that a write actually takes place to the stream.
   * However, we want to consider even the bare createWriteStream to
   * be a zipslip vulnerability since it may truncate an existing file.
   */
  class CreateWriteStreamSink extends Sink {
    CreateWriteStreamSink() {
      this = DataFlow::moduleImport("fs").getAMemberCall("createWriteStream").getArgument(0)
    }
  }

  /** A sink that is a file path that gets written to. */
  class FileSystemWriteSink extends Sink {
    FileSystemWriteSink() { exists(FileSystemWriteAccess fsw | fsw.getAPathArgument() = this) }
  }

  /**
   * Gets a string which suffices to search for to ensure that a
   * filepath will not refer to parent directories.
   */
  string getAParentDirName() { result = any(string s | s = ".." or s = "../") }

  /** A check that a path string does not include '..' */
  class NoParentDirSanitizerGuard extends SanitizerGuard {
    StringOps::Includes incl;

    NoParentDirSanitizerGuard() { this = incl }

    override predicate sanitizes(boolean outcome, Expr e) {
      incl.getPolarity().booleanNot() = outcome and
      incl.getBaseString().asExpr() = e and
      incl.getSubstring().mayHaveStringValue(getAParentDirName())
    }
  }
}
