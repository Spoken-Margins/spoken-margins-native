import Foundation

/// The order of Following's launch work (#4387, #4388). The saved Following items are already in the database, so putting
/// them on screen must never wait behind work that needs the disk audit or the network. Launch used to run one chain
/// (audit offline storage, then re-fetch every stale feed, then publish), so on a cold launch the tab stayed empty for
/// the whole chain, and the feeds then waited for an audit of about 7 GB of downloads that they don't depend on.
/// Here the saved items publish first and on their own, the audit runs beside everything, and the refresh starts as
/// soon as the saved items are out, so a refresh's publish can never be overwritten by the older first read.
public enum FollowingLaunchSequence {
    /// Starts `audit` and `publishSaved` at once, runs `refresh` as soon as `publishSaved` has finished, and returns
    /// when all three have. `refresh` does not wait for `audit`, and neither of the first two waits for the other. The
    /// steps run on the main actor, as the startup chain they replace did; their slow work is awaits on the ledger,
    /// the store and the network.
    public static func run(
        publishSaved: @escaping @MainActor @Sendable () async -> Void,
        audit: @escaping @MainActor @Sendable () async -> Void,
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        async let audited: Void = audit()
        await publishSaved()
        await refresh()
        await audited
    }
}
