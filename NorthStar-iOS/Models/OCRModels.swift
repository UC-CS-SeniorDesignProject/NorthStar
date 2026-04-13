// ocr request/response models, matches christians /v1/ocr endpoint

import Foundation

struct OCRRequest: Encodable {
    let imageB64: String
    var requestId: String?
    var options: OcrOptions?

    enum CodingKeys: String, CodingKey {
        case imageB64 = "image_b64"
        case requestId = "request_id"
        case options
    }
}

struct OcrOptions: Codable {
    var useDocOrientationClassify: Bool?
    var useDocUnwarping: Bool?
    var useTextlineOrientation: Bool?
    var textDetLimitSideLen: Int?
    var textDetLimitType: String?
    var textDetThresh: Double?
    var textDetBoxThresh: Double?
    var textDetUnclipRatio: Double?
    var textRecScoreThresh: Double?
    var maxSide: Int?
    var exifTranspose: Bool?

    enum CodingKeys: String, CodingKey {
        case useDocOrientationClassify = "use_doc_orientation_classify"
        case useDocUnwarping = "use_doc_unwarping"
        case useTextlineOrientation = "use_textline_orientation"
        case textDetLimitSideLen = "text_det_limit_side_len"
        case textDetLimitType = "text_det_limit_type"
        case textDetThresh = "text_det_thresh"
        case textDetBoxThresh = "text_det_box_thresh"
        case textDetUnclipRatio = "text_det_unclip_ratio"
        case textRecScoreThresh = "text_rec_score_thresh"
        case maxSide = "max_side"
        case exifTranspose = "exif_transpose"
    }
}


struct OCRResponse: Codable, Identifiable {
    let requestId: String
    let contentSha256: String
    let width: Int
    let height: Int
    let pages: [OCRPage]
    let timingMs: TimingInfo
    let cache: CacheInfo
    let model: ModelInfo

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case contentSha256 = "content_sha256"
        case width, height, pages
        case timingMs = "timing_ms"
        case cache, model
    }

    init(requestId: String, contentSha256: String, width: Int, height: Int, pages: [OCRPage], timingMs: TimingInfo, cache: CacheInfo, model: ModelInfo) {
        self.requestId = requestId
        self.contentSha256 = contentSha256
        self.width = width
        self.height = height
        self.pages = pages
        self.timingMs = timingMs
        self.cache = cache
        self.model = model
    }
}

struct OCRPage: Codable, Identifiable {
    let pageIndex: Int
    let blocks: [OCRBlock]
    let fullText: String

    var id: Int { pageIndex }

    enum CodingKeys: String, CodingKey {
        case pageIndex = "page_index"
        case blocks
        case fullText = "full_text"
    }

    init(pageIndex: Int, blocks: [OCRBlock], fullText: String) {
        self.pageIndex = pageIndex
        self.blocks = blocks
        self.fullText = fullText
    }
}

struct OCRBlock: Codable, Identifiable {
    let id: String
    let text: String
    let confidence: Double
    let polygon: [[Double]]
    let bboxXyxy: [Double]

    enum CodingKeys: String, CodingKey {
        case id, text, confidence, polygon
        case bboxXyxy = "bbox_xyxy"
    }

    init(id: String, text: String, confidence: Double, polygon: [[Double]], bboxXyxy: [Double]) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.polygon = polygon
        self.bboxXyxy = bboxXyxy
    }
}

struct TimingInfo: Codable {
    let decode: Double
    let preprocess: Double
    let ocrInfer: Double
    let postprocess: Double
    let total: Double

    enum CodingKeys: String, CodingKey {
        case decode, preprocess
        case ocrInfer = "ocr_infer"
        case postprocess, total
    }

    init(decode: Double = 0, preprocess: Double = 0, ocrInfer: Double = 0, postprocess: Double = 0, total: Double = 0) {
        self.decode = decode
        self.preprocess = preprocess
        self.ocrInfer = ocrInfer
        self.postprocess = postprocess
        self.total = total
    }
}

struct CacheInfo: Codable {
    let hit: Bool
    let key: String?

    init(hit: Bool = false, key: String? = nil) {
        self.hit = hit
        self.key = key
    }
}

struct ModelInfo: Codable {
    let paddleocrVersion: String

    enum CodingKeys: String, CodingKey {
        case paddleocrVersion = "paddleocr_version"
    }

    init(paddleocrVersion: String) {
        self.paddleocrVersion = paddleocrVersion
    }
}


struct BatchOCRRequest: Encodable {
    let imagesB64: [String]

    enum CodingKeys: String, CodingKey {
        case imagesB64 = "images_b64"
    }
}

struct BatchOCRResponse: Decodable {
    let requestId: String
    let results: [OCRResponse]

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case results
    }
}
