//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import LabControllerKit
import Testing

/// 遮蔽片語的整理與單次遮蔽。
///
/// 測試資料全為合成字串，不含任何真實憑證。
private final class TraceMaskerTests {

    /// 只有標了 `masked` 的變數會進片語清單。
    @Test
    func `only masked variables become phrases`() {
        let masker: TraceMasker = .init(variables: [
            .init(key: "PUBLIC", value: "plain-value"),
            .init(key: "SECRET", value: "synthetic-secret", masked: true)
        ])
        #expect(masker.phrases == ["synthetic-secret"])
    }

    /// 空值不當片語——否則每個字元邊界都會命中，整份 log 被切爛。
    @Test
    func `empty values are not phrases`() {
        #expect(TraceMasker(maskedValues: ["", "abc"]).phrases == ["abc"])
    }

    /// 重複片語去重。
    @Test
    func `duplicate phrases are deduplicated`() {
        #expect(TraceMasker(maskedValues: ["abc", "abc"]).phrases == ["abc"])
    }

    /// 片語依長度由長至短排序：短的先命中會把長的切碎、露出剩下的尾巴。
    @Test
    func `phrases are ordered longest first`() {
        let masker: TraceMasker = .init(maskedValues: ["ab", "abcdef", "abcd"])
        #expect(masker.phrases == ["abcdef", "abcd", "ab"])
        #expect(masker.mask("value=abcdef") == "value=[MASKED]")
    }

    /// 同一個值出現幾次就遮幾次。
    @Test
    func `every occurrence is replaced`() {
        let masker: TraceMasker = .init(maskedValues: ["tok"])
        #expect(masker.mask("tok and tok") == "[MASKED] and [MASKED]")
    }

    /// 沒有片語時原樣通過。
    @Test
    func `no phrases leaves text untouched`() {
        #expect(TraceMasker(maskedValues: []).mask("nothing to hide") == "nothing to hide")
    }

    /// 兩個片語在文字裡首尾重疊時整段遮掉，不得留下後者沒被前者蓋到的那一截。
    ///
    /// 逐片語依序取代會先把 `alpha-shared` 換掉，於是 `shared-omega` 剩下的 `-omega`
    /// 原樣留在 trace 上——那三個字元屬於一個被標為 masked 的值。
    @Test
    func `overlapping phrases are masked as one region`() {
        let masker: TraceMasker = .init(maskedValues: ["alpha-shared", "shared-omega"])
        #expect(masker.mask("value=alpha-shared-omega") == "value=[MASKED]")
    }

    /// 只有真正屬於片語的字元被遮，前後文原樣保留。
    @Test
    func `masking does not swallow surrounding text`() {
        let masker: TraceMasker = .init(maskedValues: ["mid"])
        #expect(masker.mask("a mid b mid c") == "a [MASKED] b [MASKED] c")
    }
}

/// 串流遮蔽：跨段邊界的行為。
private final class MaskedTraceStreamTests {

    /// 值被切成兩段送進來時仍然遮得掉——這是整個緩衝設計存在的理由。
    @Test
    func `phrase split across chunks is still masked`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: ["synthetic-secret"]))
        var emitted: String = ""
        emitted += stream.append("prefix synthetic-")
        emitted += stream.append("secret suffix")
        emitted += stream.flush()
        #expect(emitted == "prefix [MASKED] suffix")
    }

    /// 逐字元餵入也遮得掉（最極端的切法）。
    @Test
    func `phrase split character by character is still masked`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: ["abcdef"]))
        var emitted: String = ""
        for character in "x abcdef y" {
            emitted += stream.append(String(character))
        }
        emitted += stream.flush()
        #expect(emitted == "x [MASKED] y")
    }

    /// 沒有片語時等同透明通道，不押任何內容。
    @Test
    func `stream without phrases passes chunks straight through`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: []))
        #expect(stream.append("hello ") == "hello ")
        #expect(stream.append("world") == "world")
        #expect(stream.flush().isEmpty)
    }

    /// 押住的尾巴一定要靠 `flush` 放出來，否則 trace 尾端會無聲缺一截。
    @Test
    func `flush releases the held back tail`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: ["abcdef"]))
        let emitted: String = stream.append("tail")
        #expect(emitted.isEmpty)
        #expect(stream.flush() == "tail")
    }

    /// `flush` 之後緩衝區清空，不會重複吐同一段。
    @Test
    func `flush empties the buffer`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: ["abcdef"]))
        _ = stream.append("tail")
        _ = stream.flush()
        #expect(stream.flush().isEmpty)
    }

    /// 整段一次送進來、值完整落在中間時照樣遮掉。
    @Test
    func `whole chunk containing the phrase is masked`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: ["abcdef"]))
        var emitted: String = stream.append("start abcdef end")
        emitted += stream.flush()
        #expect(emitted == "start [MASKED] end")
    }
}
