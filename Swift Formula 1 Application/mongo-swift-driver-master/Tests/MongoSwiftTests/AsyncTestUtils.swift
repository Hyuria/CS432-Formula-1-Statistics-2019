import Foundation
import MongoSwift
import NIO
import TestsCommon
import XCTest

extension MongoClient {
    fileprivate static func makeTestClient(
        _ uri: String = MongoSwiftTestCase.getConnectionString(),
        eventLoopGroup: EventLoopGroup,
        options: ClientOptions? = nil
    ) throws -> MongoClient {
        var opts = options ?? ClientOptions()
        // if SSL is on and custom TLS options were not provided, enable them
        if MongoSwiftTestCase.ssl && opts.tlsCAFile == nil && opts.tlsCertificateKeyFile == nil {
            opts.tlsCAFile = URL(string: MongoSwiftTestCase.sslCAFilePath ?? "")
            opts.tlsCertificateKeyFile = URL(string: MongoSwiftTestCase.sslPEMKeyFilePath ?? "")
        }
        return try MongoClient(uri, using: eventLoopGroup, options: opts)
    }

    internal func syncCloseOrFail() {
        do {
            try self.shutdown().wait()
        } catch {
            XCTFail("Error closing test client: \(error)")
        }
    }

    internal func serverVersion() -> EventLoopFuture<ServerVersion> {
        self.db("admin").runCommand(
            ["buildInfo": 1],
            options: RunCommandOptions(readPreference: .primary)
        ).flatMapThrowing { reply in
            guard let versionString = reply["version"]?.stringValue else {
                throw TestError(message: " reply missing version string: \(reply)")
            }
            return try ServerVersion(versionString)
        }
    }
}

extension MongoDatabase {
    fileprivate func syncDropOrFail() {
        do {
            try self.drop().wait()
        } catch {
            XCTFail("Error dropping test database: \(error)")
        }
    }
}

extension MongoCollection {
    fileprivate func syncDropOrFail() {
        do {
            try self.drop().wait()
        } catch {
            XCTFail("Error dropping test collection: \(error)")
        }
    }
}

extension MongoSwiftTestCase {
    internal func withTestClient<T>(
        _ uri: String = MongoSwiftTestCase.getConnectionString(),
        options: ClientOptions? = nil,
        f: (MongoClient) throws -> T
    ) throws -> T {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { elg.syncShutdownOrFail() }
        let client = try MongoClient.makeTestClient(uri, eventLoopGroup: elg, options: options)
        defer { client.syncCloseOrFail() }
        return try f(client)
    }

    /// Creates the given namespace using the given client and passes handles to it and its parent database to the given
    /// function. After the function executes, the collection associated with the namespace is dropped.
    ///
    /// Note: If a collection is not specified as part of the input namespace, this function will throw an error.
    internal func withTestNamespace<T>(
        client: MongoClient,
        ns: MongoNamespace? = nil,
        options: CreateCollectionOptions? = nil,
        _ f: (MongoDatabase, MongoCollection<Document>) throws -> T
    ) throws -> T {
        let ns = ns ?? self.getNamespace()

        guard let collName = ns.collection else {
            throw TestError(message: "missing collection")
        }

        let database = client.db(ns.db)
        let collection: MongoCollection<Document>
        do {
            collection = try database.createCollection(collName, options: options).wait()
        } catch let error as CommandError where error.code == 48 {
            try database.collection(collName).drop().wait()
            collection = try database.createCollection(collName, options: options).wait()
        }
        defer { collection.syncDropOrFail() }
        return try f(database, collection)
    }

    /// Creates the given namespace and passes handles to it and its parents to the given function. After the function
    /// executes, the collection associated with the namespace is dropped.
    ///
    /// Note: If a collection is not specified as part of the input namespace, this function will throw an error.
    internal func withTestNamespace<T>(
        ns: MongoNamespace? = nil,
        collectionOptions: CreateCollectionOptions? = nil,
        _ f: (MongoClient, MongoDatabase, MongoCollection<Document>) throws -> T
    ) throws -> T {
        try self.withTestClient { client in
            try self.withTestNamespace(client: client, ns: ns, options: collectionOptions) { db, coll in
                try f(client, db, coll)
            }
        }
    }
}

extension MultiThreadedEventLoopGroup {
    internal func syncShutdownOrFail() {
        do {
            try self.syncShutdownGracefully()
        } catch {
            XCTFail("Error shutting down test MultiThreadedEventLoopGroup: \(error)")
        }
    }
}
