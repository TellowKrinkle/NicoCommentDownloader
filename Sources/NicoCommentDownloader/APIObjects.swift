import Foundation

struct NicoInitialWatchData: Codable {
	var context: Context
	var commentComposite: CommentComposite
	var thread: Thread
	var video: Video
	var viewer: Viewer
	struct Thread: Codable {
		var commentCount: Int
		var ids: ThreadIDs
		var serverUrl: String
		struct ThreadIDs: Codable {
			var community: String?
			var `default`: String
		}
	}
	struct CommentComposite: Codable {
		var threads: [Thread]
		struct Thread: Codable {
			var fork: Int
			var hasNicoscript: Bool
			var id: Int
			var isActive: Bool
			var isDefaultPostTarget: Bool
			var isLeafRequired: Bool
			var isOwnerThread: Bool
			var isThreadkeyRequired: Bool
			var label: String
			var postkeyStatus: Int
		}
	}
	struct Context: Codable {
		var userkey: String
		var watchId: String
		var watchTrackId: String
	}
	struct Viewer: Codable {
		var id: Int
		var isPremium: Bool
	}
	struct Video: Codable {
		var duration: Int
	}

	struct UnexpectedResponse: Error {
		var sender: String
		var response: String
	}

	func makeRequestItems(session: URLSession = URLSession.shared, userID: Int? = nil, userkey: String? = nil) throws -> [CommentRequestItem] {
		let requests = try commentComposite.threads.filter({ $0.isActive }).flatMap { thread -> [CommentRequestItem] in
			let idStr = String(thread.id)
			let userID = userID ?? viewer.id
			let userIDStr = userID == 0 ? "" : String(userID)
			let key: String? = thread.isThreadkeyRequired ? nil : userkey ?? context.userkey
			var threadkey: String? = nil
			var force184: String? = nil
			if thread.isThreadkeyRequired {
				let data = try session.blockingHTTP200OnlyDataTask(with: URL(string: "https://flapi.nicovideo.jp/api/getthreadkey?thread=\(thread.id)")!)
				let str = String(decoding: Array(data), as: UTF8.self)
				for piece in str.split(separator: "&") {
					let halves = piece.split(separator: "=")
					if halves.count != 2 {
						throw UnexpectedResponse(sender: "GetThreadKey", response: str)
					}
					switch halves[0] {
					case "threadkey":
						threadkey = String(halves[1])
					case "force_184":
						force184 = String(halves[1])
					default:
						throw UnexpectedResponse(sender: "GetThreadKey", response: str)
					}
				}
			}
			let threadReq = CommentRequestItem.Thread(thread: idStr, version: "20090904", fork: thread.fork, language: 0, numRes: nil, userID: userIDStr, withGlobal: 1, scores: 1, nicoru: 3, userkey: key, threadkey: threadkey, force184: force184)
			let leafReq = CommentRequestItem.ThreadLeaves(thread: idStr, language: 0, userID: userIDStr, content: .init(videoLengthSec: video.duration, commentsPerLeaf: 100, union: 1000, newNicoru: true), scores: 1, nicoru: 3, userkey: key, threadkey: threadkey, force184: force184)
			return [CommentRequestItem.thread(threadReq), CommentRequestItem.threadLeaves(leafReq)]
		}
		let start = CommentRequestItem.ping(.init(type: .requestStart, id: 0))
		let end = CommentRequestItem.ping(.init(type: .requestFinish, id: 0))
		let packets = requests.enumerated().flatMap { (offset, element) -> [CommentRequestItem] in
			return [
				CommentRequestItem.ping(.init(type: .packetStart, id: offset)),
				element,
				CommentRequestItem.ping(.init(type: .packetFinish, id: offset))
			]
		}
		return [start] + packets + [end]
	}
}

enum CommentRequestItem: Encodable {
	case ping(Ping)
	case thread(Thread)
	case threadLeaves(ThreadLeaves)

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .ping(let ping):
			try ping.encode(to: container.superEncoder(forKey: .ping))
		case .thread(let thread):
			try thread.encode(to: container.superEncoder(forKey: .thread))
		case .threadLeaves(let leaves):
			try leaves.encode(to: container.superEncoder(forKey: .threadLeaves))
		}
	}

	struct Ping: Encodable {
		var type: PingType
		var id: Int

		func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode("\(type.rawValue):\(id)", forKey: .content)
		}

		enum PingType: String {
			case requestStart = "rs"
			case requestFinish = "rf"
			case packetStart = "ps"
			case packetFinish = "pf"
		}

		enum CodingKeys: String, CodingKey {
			case content
		}
	}
	struct Thread: Codable {
		var thread: String
		var version: String
		var fork: Int
		var language: Int
		var numRes: Int?
		var userID: String
		var withGlobal: Int
		var scores: Int
		var nicoru: Int
		var userkey: String?
		var threadkey: String?
		var force184: String?

		private enum CodingKeys: String, CodingKey {
			case thread, version, fork, language, scores, nicoru, userkey, threadkey
			case numRes = "num_res"
			case userID = "user_id"
			case withGlobal = "with_global"
			case force184 = "force_184"
		}
	}
	struct ThreadLeaves: Encodable {
		var thread: String
		var language: Int
		var userID: String
		var content: Content
		var scores: Int
		var nicoru: Int
		var userkey: String?
		var threadkey: String?
		var force184: String?

		struct Content: Encodable {
			var numLeaves: Int
			var commentsPerLeaf: Int
			var union: Int?
			var newNicoru: Bool
			func encode(to encoder: Encoder) throws {
				let unionStr = union.map { ",\($0)" } ?? ""
				let nnstr = newNicoru ? ",nicoru:100" : ""
				let str = "0-\(numLeaves):\(commentsPerLeaf)\(unionStr)\(nnstr)"
				try str.encode(to: encoder)
			}
			init(videoLengthSec: Int, commentsPerLeaf: Int, union: Int?, newNicoru: Bool) {
				numLeaves = (videoLengthSec + 59) / 60
				self.commentsPerLeaf = commentsPerLeaf
				self.union = union
				self.newNicoru = newNicoru
			}
		}

		private enum CodingKeys: String, CodingKey {
			case thread, language, content, scores, nicoru, userkey, threadkey
			case userID = "user_id"
			case force184 = "force_184"
		}
	}
	private enum CodingKeys: String, CodingKey {
		case ping
		case thread
		case threadLeaves = "thread_leaves"
	}
}
