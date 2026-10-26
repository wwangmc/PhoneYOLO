#include "../Sources/PYAlgorithms.hpp"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <limits>

static void near(double a, double b) { assert(std::abs(a - b) < 0.01); }
static std::vector<uint8_t> masked(uint8_t op, const std::vector<uint8_t> &data) {
    auto f = py::frame(op, data.data(), data.size());
    size_t header = f.size() - data.size();
    f[1] |= 128;
    const uint8_t key[] = {1, 7, 3, 9};
    f.insert(f.begin() + header, key, key + 4);
    for (size_t i = 0; i < data.size(); i++)
        f[header + 4 + i] ^= key[i % 4];
    return f;
}
int main(int argc, char **argv) {
    py::Box a{0, 0, 10, 10, .9, 0}, b{1, 1, 10, 10, .8, 0}, c{1, 1, 10, 10, .7, 1};
    near(py::iou(a, a), 1);
    assert(py::nms({b, c, a}, .45, 100).size() == 2);
    assert(py::nms({a, c}, .45, 1).size() == 1);
    auto portrait = py::unletterbox({160, 0, 320, 640, .9, 0}, 1080, 2160, 640, 640);
    near(portrait.x, 0);
    near(portrait.y, 0);
    near(portrait.w, 1080);
    near(portrait.h, 2160);
    auto landscape = py::unletterbox({0, 160, 640, 320, .9, 0}, 2160, 1080, 640, 640);
    near(landscape.w, 2160);
    near(landscape.h, 1080);
    auto padding = py::unletterbox({0, 0, 100, 100, .9, 0}, 1080, 2160, 640, 640);
    near(padding.w, 0);
    float values[6][3] = {{320, 320, 320}, {320, 320, 320}, {100, 100, 100},
                          {100, 100, 100}, {.9f, .8f, 0},   {0, 0, .7f}};
    auto read = [&](size_t ch, size_t n) { return values[ch][n]; };
    assert(py::decode(3, 2, read, .25, .45, 100, 640, 640, 640, 640).size() == 2);
    values[0][0] = std::numeric_limits<float>::quiet_NaN();
    values[4][1] = 0;
    values[5][2] = 0;
    assert(py::decode(3, 2, read, .25, .45, 100, 640, 640, 640, 640).empty());
    for (size_t length : {size_t(0), size_t(5), size_t(125), size_t(126), size_t(65535), size_t(65536)}) {
        std::vector<uint8_t> data(length, 42);
        auto wire = masked(1, data);
        py::Frame frame;
        for (size_t split = 0; split < std::min(size_t(16), wire.size()); split++)
            assert(py::parseFrame(wire.data(), split, frame) == py::Parse::More);
        assert(py::parseFrame(wire.data(), wire.size(), frame) == py::Parse::Ready);
        assert(frame.payload == data && frame.consumed == wire.size());
        wire[1] &= 127;
        assert(py::parseFrame(wire.data(), wire.size(), frame) == py::Parse::Invalid);
    }
    auto ping = masked(9, {1, 2, 3});
    py::Frame frame;
    assert(py::parseFrame(ping.data(), ping.size(), frame) == py::Parse::Ready && frame.opcode == 9);
    ping[0] &= 127;
    assert(py::parseFrame(ping.data(), ping.size(), frame) == py::Parse::Invalid);
    auto huge = masked(1, std::vector<uint8_t>(65537));
    assert(py::parseFrame(huge.data(), huge.size(), frame) == py::Parse::TooLarge);
    auto close = masked(8, {1});
    assert(py::parseFrame(close.data(), close.size(), frame) == py::Parse::Invalid);
    // Real YOLOv8 raw predictions. Generated independently using Ultralytics' NMS.
    if (argc == 3) {
        std::ifstream raw(argv[1], std::ios::binary), expected(argv[2]);
        assert(raw && expected);
        std::vector<float> tensor(84 * 8400);
        raw.read((char *)tensor.data(), (std::streamsize)(tensor.size() * sizeof(float)));
        assert(raw.gcount() == (std::streamsize)(tensor.size() * sizeof(float)));
        auto boxes = py::decode(
            8400, 80, [&](size_t ch, size_t n) { return tensor[ch * 8400 + n]; }, .25, .45, 100, 640, 640,
            640, 640);
        size_t count;
        expected >> count;
        assert(boxes.size() == count);
        for (const auto &box : boxes) {
            double x, y, w, h, score;
            int cls;
            expected >> x >> y >> w >> h >> score >> cls;
            near(box.x, x);
            near(box.y, y);
            near(box.w, w);
            near(box.h, h);
            near(box.score, score);
            assert(box.cls == cls);
        }
    }
    std::puts("PASS: letterbox, YOLO decode/NMS, invalid values, masked frames, partial frames, ping and "
              "size limits");
}
