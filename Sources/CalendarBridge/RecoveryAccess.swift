import CalendarBridgeCore
import Foundation

/// The only EventKit effects used by rollback and reconciliation. Synthetic
/// service tests inject this boundary without constructing an EKEventStore.
package enum RecordedLookup {
  case found(RecordedItem)
  case absent
}

package struct RecordedItem {
  package let currentSnapshot: () throws -> ItemSnapshot
  package let remove: (String?) throws -> Void
  package let restore: (ItemSnapshot) throws -> ItemSummary

  package init(
    currentSnapshot: @escaping () throws -> ItemSnapshot,
    remove: @escaping (String?) throws -> Void,
    restore: @escaping (ItemSnapshot) throws -> ItemSummary
  ) {
    self.currentSnapshot = currentSnapshot
    self.remove = remove
    self.restore = restore
  }
}

package protocol RecoveryBackend {
  func lookup(id: String?, externalId: String?, snapshot: ItemSnapshot?, kind: ItemKind)
    throws -> RecordedLookup
  func validateRestoreContainer(_ snapshot: ItemSnapshot) throws
  func recreateDeleted(_ snapshot: ItemSnapshot) throws -> ItemSummary
}
