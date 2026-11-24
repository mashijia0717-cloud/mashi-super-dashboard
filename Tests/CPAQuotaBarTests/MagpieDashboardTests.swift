import Foundation
import Testing
@testable import CPAQuotaBar

struct MagpieDashboardTests {
    private let connection = MagpieServerConnection(serverURL: "https://magpie.example.com", webKey: "existing-server-key-0123456789")

    @Test func pageLinksSelectTheOriginalServerViewsWithoutCredentials() throws {
        let root = try #require(connection.url)
        let routing = try #require(URLComponents(url: MagpieServerPage.routing.url(at: root), resolvingAgainstBaseURL: false))
        let usage = try #require(URLComponents(url: MagpieServerPage.usage.url(at: root), resolvingAgainstBaseURL: false))
        #expect(routing.host == "magpie.example.com")
        #expect(routing.queryItems == [URLQueryItem(name: "view", value: "routing")])
        #expect(usage.queryItems == [URLQueryItem(name: "view", value: "usage"), URLQueryItem(name: "tab", value: "usage")])
        #expect(!MagpieServerPage.usage.url(at: root).absoluteString.contains(connection.webKey))
    }

    @Test func websiteCookieIsHttpOnlyAndScopedToTheServer() throws {
        let cookie = try #require(connection.cookie)
        #expect(cookie.name == "magpie_web_3430")
        #expect(cookie.domain == "magpie.example.com")
        #expect(cookie.path == "/")
        #expect(cookie.isHTTPOnly)
        #expect(cookie.isSecure)
        #expect(cookie.isSessionOnly)
    }

    @Test func navigationDoesNotSendTheSessionToAnotherOrigin() {
        #expect(connection.allows(URL(string: "https://magpie.example.com/?view=usage")!))
        #expect(connection.allows(URL(string: "https://magpie.example.com:443/api/usage")!))
        #expect(!connection.allows(URL(string: "http://magpie.example.com/")!))
        #expect(!connection.allows(URL(string: "https://magpie.example.com:3430/")!))
        #expect(!connection.allows(URL(string: "https://another.example.com/")!))
        #expect(!connection.allows(URL(string: "http://127.0.0.1:3425/")!))
    }

    @Test func connectionRejectsLocalSourcesAndKeysInTheAddress() {
        #expect(connection.isValid)
        for address in ["http://localhost:3425", "http://127.0.0.1:3425", "http://[::1]:3425",
                        "file:///tmp/page.html", "https://user:pass@magpie.example.com",
                        "https://magpie.example.com/?k=secret", "https://magpie.example.com/#secret",
                        "https://magpie.example.com/api"] {
            #expect(!MagpieServerConnection(serverURL: address, webKey: connection.webKey).isValid)
        }
        #expect(!MagpieServerConnection(serverURL: connection.serverURL, webKey: "a short key").isValid)
    }
}
