import Foundation

/// The order of Following's launch work (#4387). The saved Following items are already in the database, so putting
/// them on screen must never wait behind work that needs the disk audit or the network. Launch used to run one chain
/// (audit offline storage, then re-fetch every stale feed, then publish), so on a cold launch the tab stayed empty for
/// the whole chain. Here the saved items publish first and on their own; the audit runs beside that; the refresh
/// starts only after both, so a refresh's publish can never be overwritten by the older first read.
public enum FollowingLaunchSequence {
    /// Starts `publishSaved` at once, runs `audit` beside it, then runs `refresh` once both have finished.
    /// `publishSaved` does not wait for `audit`, and `audit` does not wait for `publishSaved`. The steps run on the main
    /// actor, as the startup chain they replace did; their slow work is awaits on the ledger and the store.
    public static func run(
        publishSaved: @escaping @MainActor @Sendable () async -> Void,
        audit: @escaping @MainActor @Sendable () async -> Void,
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        async let published: Void = publishSaved()
        await audit()
        await published
        await refresh()
    }
}
