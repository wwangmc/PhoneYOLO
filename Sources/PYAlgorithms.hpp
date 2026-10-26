#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace py {
struct Box {
    double x, y, w, h, score;
    int cls;
};
inline double iou(const Box &a, const Box &b) {
    double area = std::max(0.0, std::min(a.x + a.w, b.x + b.w) - std::max(a.x, b.x)) *
                  std::max(0.0, std::min(a.y + a.h, b.y + b.h) - std::max(a.y, b.y));
    double total = a.w * a.h + b.w * b.h - area;
    return total > 0 ? area / total : 0;
}
inline std::vector<Box> nms(std::vector<Box> boxes, double threshold, size_t limit) {
    std::stable_sort(boxes.begin(), boxes.end(),
                     [](const Box &a, const Box &b) { return a.score > b.score; });
    if (boxes.size() > 3000)
        boxes.resize(3000);
    std::vector<Box> out;
    for (auto &b : boxes) {
        bool keep = true;
        for (auto &picked : out)
            if (picked.cls == b.cls && iou(picked, b) > threshold) {
                keep = false;
                break;
            }
        if (keep)
            out.push_back(b);
        if (out.size() >= limit)
            break;
    }
    return out;
}
// Inverse letterbox. Coordinates are top-left origin pixels in the oriented screen.
inline Box unletterbox(Box b, double sw, double sh, double mw, double mh) {
    double scale = std::min(mw / sw, mh / sh), px = (mw - sw * scale) / 2, py = (mh - sh * scale) / 2;
    double x1 = std::clamp((b.x - px) / scale, 0.0, sw), y1 = std::clamp((b.y - py) / scale, 0.0, sh);
    double x2 = std::clamp((b.x + b.w - px) / scale, 0.0, sw),
           y2 = std::clamp((b.y + b.h - py) / scale, 0.0, sh);
    return {x1, y1, std::max(0.0, x2 - x1), std::max(0.0, y2 - y1), b.score, b.cls};
}
template <class Read>
std::vector<Box> decode(size_t count, size_t classes, Read read, double confidence, double threshold,
                        size_t limit, double sw, double sh, double mw, double mh) {
    std::vector<Box> candidates;
    for (size_t n = 0; n < count; n++) {
        double score = 0;
        int cls = -1;
        for (size_t c = 0; c < classes; c++) {
            double p = read(c + 4, n);
            if (std::isfinite(p) && p > score) {
                score = p;
                cls = (int)c;
            }
        }
        if (cls < 0 || score < confidence || score > 1)
            continue;
        double cx = read(0, n), cy = read(1, n), w = read(2, n), h = read(3, n);
        if (!std::isfinite(cx) || !std::isfinite(cy) || !std::isfinite(w) || !std::isfinite(h) || w <= 0 ||
            h <= 0)
            continue;
        Box b = unletterbox({cx - w / 2, cy - h / 2, w, h, score, cls}, sw, sh, mw, mh);
        if (b.w > 0 && b.h > 0)
            candidates.push_back(b);
    }
    return nms(std::move(candidates), threshold, limit);
}

struct Frame {
    uint8_t opcode = 0;
    bool fin = true;
    std::vector<uint8_t> payload;
    size_t consumed = 0;
};
enum class Parse { More, Ready, Invalid, TooLarge };
inline Parse parseFrame(const uint8_t *p, size_t size, Frame &f) {
    if (size < 2)
        return Parse::More;
    f.fin = (p[0] & 128) != 0;
    f.opcode = p[0] & 15;
    if ((p[0] & 0x70) || !(p[1] & 128) ||
        !(f.opcode == 0 || f.opcode == 1 || f.opcode == 2 || f.opcode == 8 || f.opcode == 9 ||
          f.opcode == 10))
        return Parse::Invalid;
    uint64_t len = p[1] & 127;
    size_t offset = 2;
    if (len == 126) {
        if (size < 4)
            return Parse::More;
        len = ((uint64_t)p[2] << 8) | p[3];
        offset = 4;
        if (len < 126)
            return Parse::Invalid;
    } else if (len == 127) {
        if (size < 10)
            return Parse::More;
        if (p[2] & 128)
            return Parse::Invalid;
        len = 0;
        for (int i = 2; i < 10; i++)
            len = (len << 8) | p[i];
        offset = 10;
        if (len < 65536)
            return Parse::Invalid;
    }
    if (f.opcode >= 8 && (!f.fin || len > 125 || (f.opcode == 8 && len == 1)))
        return Parse::Invalid;
    if (len > 65536)
        return Parse::TooLarge;
    if (size < offset + 4 + len)
        return Parse::More;
    f.payload.resize((size_t)len);
    for (size_t i = 0; i < len; i++)
        f.payload[i] = p[offset + 4 + i] ^ p[offset + (i % 4)];
    f.consumed = offset + 4 + (size_t)len;
    return Parse::Ready;
}
inline std::vector<uint8_t> frame(uint8_t opcode, const void *bytes, size_t size) {
    std::vector<uint8_t> out{(uint8_t)(128 | opcode)};
    if (size < 126)
        out.push_back((uint8_t)size);
    else if (size <= 65535) {
        out.push_back(126);
        out.push_back((uint8_t)(size >> 8));
        out.push_back((uint8_t)size);
    } else {
        out.push_back(127);
        for (int i = 7; i >= 0; i--)
            out.push_back((uint8_t)((uint64_t)size >> (8 * i)));
    }
    const auto *p = (const uint8_t *)bytes;
    if (size)
        out.insert(out.end(), p, p + size);
    return out;
}
} // namespace py
