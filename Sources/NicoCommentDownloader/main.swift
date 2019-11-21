import SwiftSoup
import Foundation

func printStdError(_ str: String) {
	FileHandle.standardError.write(Data(str.utf8))
	FileHandle.standardError.write(Data("\n".utf8))
}

func exitWithError(_ error: String) -> Never {
	printStdError(error)
	exit(EXIT_FAILURE)
}

protocol HTTPDataTaskable {
	func makeDataTask(using urlsession: URLSession, completionHandler: @escaping (Data?, URLResponse?, Error?) -> ()) -> URLSessionDataTask
	var url: URL { get }
}

extension URLRequest: HTTPDataTaskable {
	var url: URL {
		return self.mainDocumentURL!
	}

	func makeDataTask(using urlsession: URLSession, completionHandler: @escaping (Data?, URLResponse?, Error?) -> ()) -> URLSessionDataTask {
		urlsession.dataTask(with: self, completionHandler: completionHandler)
	}
}

extension URL: HTTPDataTaskable {
	func makeDataTask(using urlsession: URLSession, completionHandler: @escaping (Data?, URLResponse?, Error?) -> ()) -> URLSessionDataTask {
		urlsession.dataTask(with: self, completionHandler: completionHandler)
	}

	var url: URL { return self }
}

extension URLSession {
	struct NonHTTPError: Error {}
	struct BadResponseError: LocalizedError {
		var url: URL
		var code: Int
		var data: Data
		var errorDescription: String? {
			return "Got bad response \(code) from \(url): " + String(decoding: Array(data), as: UTF8.self)
		}
	}

	func blockingHTTPDataTask<T: HTTPDataTaskable>(with request: T) throws -> (Data, HTTPURLResponse) {
		let group = DispatchGroup()
		group.enter()
		var retVal: (Data?, URLResponse?, Error?)? = nil
		request.makeDataTask(using: self) { data, response, error in
			retVal = (data, response, error)
			group.leave()
		}.resume()
		group.wait()
		let (data, response, error) = retVal!
		if let error = error { throw error }
		guard let httpResp = response as? HTTPURLResponse else { throw NonHTTPError() }
		return (data!, httpResp)
	}

	func blockingHTTP200OnlyDataTask<T: HTTPDataTaskable>(with request: T) throws -> Data {
		let (data, response) = try blockingHTTPDataTask(with: request)
		if response.statusCode == 200 { return data }
		throw BadResponseError(url: request.url, code: response.statusCode, data: data)
	}
}

guard let url = CommandLine.arguments.dropFirst().first.flatMap(URL.init(string:)) else {
	exitWithError("Usage: \(CommandLine.arguments[0]) nicoURL")
}

let session = URLSession(configuration: .default)

if let user = ProcessInfo.processInfo.environment["nicouser"], let pass = ProcessInfo.processInfo.environment["nicopass"] {
	printStdError("Logging in as \(user)...")
	var request = URLRequest(url: URL(string: "https://account.nicovideo.jp/api/v1/login?site=niconico")!)
	request.httpMethod = "POST"
	request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type");
	var set = CharacterSet.urlQueryAllowed
	set.remove("+")
	request.httpBody = Data("mail_tel=\(user.addingPercentEncoding(withAllowedCharacters: set)!)&password=\(pass.addingPercentEncoding(withAllowedCharacters: set)!)".utf8)
	_ = try session.blockingHTTP200OnlyDataTask(with: request)
	if session.configuration.httpCookieStorage?.cookies?.contains(where: { $0.name == "user_session" }) != true {
		printStdError("Failed to log in")
	}
}
else {
	printStdError("Not logging in, set the environment variables nicouser and nicopass to log in")
}

let mainPage = try session.blockingHTTP200OnlyDataTask(with: url)
let parsed = try SwiftSoup.parse(String(decoding: Array(mainPage), as: UTF8.self), url.absoluteString)
guard let watchData = try parsed.getElementById("js-initial-watch-data") else {
	exitWithError("Failed to get initial watch data")
}
let attrData = try watchData.attr("data-api-data")

let apiObject = try JSONDecoder().decode(NicoInitialWatchData.self, from: Data(attrData.utf8))

if apiObject.viewer.id != 0 {
	printStdError("Logged in as ID \(apiObject.viewer.id) with key \(apiObject.context.userkey)")
}

FileHandle.standardError.write(Data("Video has \(apiObject.thread.commentCount) comments\n".utf8))
let reqURL = URL(string: apiObject.thread.serverUrl.replacingOccurrences(of: "/api/", with: "/api.json/"))!

var request = URLRequest(url: reqURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
request.httpMethod = "POST"
request.httpBody = try JSONEncoder().encode(try apiObject.makeRequestItems(session: session))
request.addValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")

FileHandle.standardOutput.write(try session.blockingHTTP200OnlyDataTask(with: request))
