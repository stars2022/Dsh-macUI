import Foundation

@main
enum ImageAttachmentValidation {
    static func main() {
        let json: [String: Any] = [
            "maxImageBytes": 5 * 1_048_576,
            "maxImagesPerMessage": 20,
            "maxMessageImageBytes": 100 * 1_048_576,
            "maxImagePixels": 40_000_000,
            "mediaTypes": ["image/png", "image/jpeg", "image/webp", "image/gif"],
        ]
        let limits = ImageAttachmentLimits(json: json)
        precondition(limits?.maxImagesPerMessage == 20)
        precondition(limits?.perImageSizeText == "5MB")
        precondition(limits?.totalSizeText == "100MB")

        let envelope: [String: Any] = [
            "code": "attachment-error",
            "message": "Attachment rejected",
            "details": ["reason": "IMAGE_TOO_LARGE"],
        ]
        let error = APIError.rpcServer(json: envelope)
        precondition(error.serverCode == "attachment-error")
        precondition(error.serverReason == "IMAGE_TOO_LARGE")

        expect("MODEL_DOES_NOT_SUPPORT_IMAGES", "当前模型不支持图片，请切换支持图片的模型", limits)
        expect("SUBAGENT_IMAGE_UNSUPPORTED", "子智能体会话暂不支持图片", limits)
        expect("IMAGE_TOO_MANY_PIXELS", "图片分辨率过大，请压缩后重试", limits)
        expect("INVALID_IMAGE", "仅支持 PNG、JPG、WebP、GIF 格式的图片", limits)
        expect("IMAGE_TYPE_MISMATCH", "仅支持 PNG、JPG、WebP、GIF 格式的图片", limits)
        expect("TOO_MANY_IMAGES", "一条消息最多添加 20 张图片", limits)
        expect("IMAGE_TOO_LARGE", "单张图片不能超过 5MB", limits)
        expect("IMAGES_TOO_LARGE", "图片总大小超过 100MB，请移除部分图片", limits)
        expect("FUTURE_REASON", "图片发送失败（FUTURE_REASON），请重新添加图片后再试", limits)
        expect("TOO_MANY_IMAGES", "图片发送失败（TOO_MANY_IMAGES），请重新添加图片后再试", nil)
        print("ImageAttachmentValidation: limits, RPC reason and 10 copy fixtures passed")
    }

    private static func expect(_ reason: String, _ expected: String, _ limits: ImageAttachmentLimits?) {
        precondition(attachmentErrorText(reason: reason, limits: limits) == expected)
    }
}
