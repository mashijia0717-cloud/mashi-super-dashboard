import CoreGraphics
import Testing
@testable import CPAQuotaBar

@Test func staleExternalRowCannotTargetAReusedBuiltinIdentifier() {
    let external = ConnectedDisplay(id: 2, index: 1, name: "AOC", isBuiltin: false)
    let builtin = ConnectedDisplay(id: 2, index: 1, name: "Color LCD", isBuiltin: true)
    #expect(!DisplaySafetyPolicy.matchesCurrentDisplay(external, current: [builtin]))
    #expect(!DisplaySafetyPolicy.matchesCurrentDisplay(external, current: []))
    #expect(DisplaySafetyPolicy.matchesCurrentDisplay(external, current: [external]))
}

@Test func staleExternalSnapshotDoesNotEndTheFiniteRecoveryBurst() {
    #expect(DisplaySafetyPolicy.shouldRetryRecovery(code: 0, output: #"{"ok":true,"skipped":"external-available"}"#))
    #expect(DisplaySafetyPolicy.shouldRetryRecovery(code: 1, output: "temporarily unavailable"))
    #expect(!DisplaySafetyPolicy.shouldRetryRecovery(code: 0, output: #"{"ok":true,"skipped":"no-owned-state"}"#))
    #expect(!DisplaySafetyPolicy.shouldRetryRecovery(code: 0, output: #"{"ok":true}"#))
}

@Test func lastBuiltinCannotBeHiddenWithMissingOrUnknownExternalTopology() {
    #expect(!DisplaySafetyPolicy.mayHideBuiltin(usableExternalCount: 0))
    #expect(DisplaySafetyPolicy.mayHideBuiltin(usableExternalCount: 1))
}

@Test func unplugReleasesOnlyOwnedBuiltinMasksAndKeepsExternalPreference() {
    let owned: Set<CGDirectDisplayID> = [1, 2]
    #expect(DisplaySafetyPolicy.builtinMasksToRelease(builtinIDs: [1, 3], ownedIDs: owned, usableExternalCount: 0) == [1])
    #expect(DisplaySafetyPolicy.builtinMasksToRelease(builtinIDs: [1, 3], ownedIDs: owned, usableExternalCount: 1).isEmpty)
    #expect(DisplaySafetyPolicy.builtinMasksToRelease(builtinIDs: [1], ownedIDs: [], usableExternalCount: 0).isEmpty)
}
