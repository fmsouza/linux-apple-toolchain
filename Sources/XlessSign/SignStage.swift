import Foundation
import XlessASC
import XlessCore

public enum SignStage {
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL,
                           secrets: Secrets, client: ASCClient) async throws -> URL {
        try await Files.atomicOutput(outputDir) { partial in
            try await sign(input: input, into: partial, platform: platform, config: config, project: project, secrets: secrets, client: client)
        }
    }

    static func sign(input: URL, into outputDir: URL, platform: Platform, config: ProjectConfig, project: URL,
                     secrets: Secrets, client: ASCClient) async throws -> URL {
        let pc = try config.platform(platform)
        let distribution = config.distribution(for: platform)
        let kind: CertificateKind = distribution == .appStore ? .distribution : .developerID
        let key = try SigningKey(pem: secrets.required(kind.secretName, stage: .sign))
        let bundleID = config.bundleID(for: platform)

        let certService = CertificateService(client: client)
        let profiles = ProfileService(client: client)
        let cert = try await certService.find(matching: key, kind: kind)
        let bundleResource = try await profiles.ensureBundleID(identifier: bundleID, platform: platform)
        let profile = try await profiles.ensureProfile(bundleIDResourceID: bundleResource, certificateID: cert.id,
                                                       type: .for(platform: platform), bundleIdentifier: bundleID)

        // Every check runs before the bundle is touched.
        let user = try pc.entitlements.map { try Plist.read(project.appendingPathComponent($0), stage: .sign) } ?? [:]
        let profileEntitlements = try Entitlements.extract(fromProfile: profile)
        try Entitlements.checkTeam(profile: profileEntitlements, teamID: config.teamID)
        let ents = try Entitlements.merge(user: user, profile: profileEntitlements,
                                          platform: platform, teamID: config.teamID, bundleID: bundleID)
        guard let der = cert.attributes.certificateContent.flatMap({ Data(base64Encoded: $0) }) else {
            throw XlessError(.sign, "certificate \(cert.id) has no content", fix: "re-run; if it persists, check the certificate in App Store Connect")
        }

        let app = try Files.copyBundle(input, intoFreshDir: outputDir)
        let layout = BundleLayout(platform: platform)
        let profileURL = app.appendingPathComponent(layout.embeddedProfile)
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try profile.write(to: profileURL)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keyURL = tmp.appendingPathComponent("key.pem"), certURL = tmp.appendingPathComponent("cert.pem"), entURL = tmp.appendingPathComponent("ent.plist")
        guard FileManager.default.createFile(atPath: keyURL.path, contents: Data(key.pem.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw XlessError(.sign, "cannot write signing key to temp dir", fix: "check free space and permissions of \(FileManager.default.temporaryDirectory.path)")
        }
        let certPEM = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
        try Plist.write(ents, to: entURL, format: .xml, stage: .sign)

        try Shell.run("rcodesign", RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: distribution),
                      stage: .sign)
        return app
    }
}
