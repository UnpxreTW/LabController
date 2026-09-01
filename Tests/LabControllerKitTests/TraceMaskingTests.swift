//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LabControllerKit
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
        #expect(TraceMasker(maskedValues: ["", "abcd"]).phrases == ["abcd"])
    }

    /// 短於下限的值不遮：那個長度的字串會命中幾乎每一行，而它本來也不可能是憑證。
    @Test
    func `phrases shorter than the minimum are dropped`() {
        let masker: TraceMasker = .init(maskedValues: ["t", "abc", "abcd"])
        #expect(masker.phrases == ["abcd"])
        #expect(masker.mask("t abc abcd") == "t abc [MASKED]")
    }

    /// 重複片語去重。
    @Test
    func `duplicate phrases are deduplicated`() {
        #expect(TraceMasker(maskedValues: ["abcd", "abcd"]).phrases == ["abcd"])
    }

    /// 片語依長度由長至短排序：短的先命中會把長的切碎、露出剩下的尾巴。
    @Test
    func `phrases are ordered longest first`() {
        let masker: TraceMasker = .init(maskedValues: ["abcd", "abcdefgh", "abcdef"])
        #expect(masker.phrases == ["abcdefgh", "abcdef", "abcd"])
        #expect(masker.mask("value=abcdefgh") == "value=[MASKED]")
    }

    /// 同一個值出現幾次就遮幾次。
    @Test
    func `every occurrence is replaced`() {
        let masker: TraceMasker = .init(maskedValues: ["tok3n"])
        #expect(masker.mask("tok3n and tok3n") == "[MASKED] and [MASKED]")
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
        let masker: TraceMasker = .init(maskedValues: ["midd"])
        #expect(masker.mask("a midd b midd c") == "a [MASKED] b [MASKED] c")
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

    /// 一個片語是另一個片語的前綴時，跨段仍不得露出長片語多出來的那一截。
    ///
    /// 這是「緩衝區存原文」的理由：存已遮過的文字，短片語會在前半段就被換掉、原文銷毀，
    /// 長片語之後永遠對不上，多出來的尾巴照樣送上站台。
    @Test
    func `phrase that is a prefix of another does not leak its tail across chunks`() {
        var stream: MaskedTraceStream = .init(
            masker: .init(maskedValues: ["synthetic-token", "synthetic-token-long"])
        )
        var emitted: String = ""
        emitted += stream.append("value=synthetic-token")
        emitted += stream.append("-long end")
        emitted += stream.flush()
        #expect(emitted == "value=[MASKED] end")
    }

    /// 分段送出的結果必須與一次送出的結果一致——切法不該改變遮蔽結果。
    @Test
    func `streamed output matches whole text masking for every split point`() {
        let masker: TraceMasker = .init(maskedValues: ["synthetic-token", "synthetic-token-long", "second"])
        let text: String = "a synthetic-token-long b second c synthetic-token d"
        let expected: String = masker.mask(text)
        for split in 0 ... text.count {
            var stream: MaskedTraceStream = .init(masker: masker)
            let index: String.Index = text.index(text.startIndex, offsetBy: split)
            var emitted: String = stream.append(String(text[..<index]))
            emitted += stream.append(String(text[index...]))
            emitted += stream.flush()
            #expect(emitted == expected, "切在第 \(split) 個字元時結果不一致")
        }
    }

    /// 整段一次送進來、值完整落在中間時照樣遮掉。
    @Test
    func `whole chunk containing the phrase is masked`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: ["abcdef"]))
        var emitted: String = stream.append("start abcdef end")
        emitted += stream.flush()
        #expect(emitted == "start [MASKED] end")
    }

    /// 片語首尾相接鋪滿整個緩衝區時 trace 仍必須前進。
    ///
    /// 切點會一路退到 0（整段都在命中區間內），沒有強制放行的出口就會變成：緩衝區隨輸出
    /// 線性成長、每輪重掃退化成 O(n²)，站台端看到一個「跑很久卻零輸出」的 job。
    @Test
    func `contiguous phrase repetition still makes progress`() {
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: ["synthetic-secret"]))
        var emitted: String = ""
        for _ in 0 ..< 2000 {
            emitted += stream.append("synthetic-secret")
        }
        #expect(!emitted.isEmpty, "緩衝區卡住＝trace 完全停送")
        // 只驗「有輸出」不夠：上限訂成十倍大它照樣有輸出、只是慢。要驗的是緩衝區真的有界。
        #expect(stream.bufferedCharacterCount <= 4 * 16 + 16)
        emitted += stream.flush()
        // 內容全是秘密，因此輸出只能由遮蔽字樣組成——一個原始字元都不許漏。
        #expect(emitted.replacingOccurrences(of: "[MASKED]", with: "").isEmpty)
    }

    /// 強制放行不得把秘密後面的正常 trace 一起吞掉。
    ///
    /// 押住的尾巴橫跨「秘密結尾」與「其後的明文」時，若整段標成已覆蓋，那段明文會被併進
    /// 遮蔽字樣、永遠送不出去——而且不留任何徵兆說少了東西。
    @Test
    func `forced release does not swallow trailing plain text`() {
        let secret: String = "synthetic-secret"
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: [secret]))
        var emitted: String = stream.append(String(repeating: secret, count: 5) + "ERROR")
        emitted += stream.flush()
        #expect(emitted.contains("ERROR"))
        #expect(!emitted.contains("synthetic"))
    }

    /// 分段送與一次送的差異只允許出現在「遮蔽字樣被拆成幾個」，明文部分必須逐字相同。
    @Test
    func `forced release preserves every plain character`() {
        let secret: String = "synthetic-secret"
        let text: String = String(repeating: secret, count: 6) + "tail-marker" + secret + "end"
        let masker: TraceMasker = .init(maskedValues: [secret])
        for chunkSize in [1, 7, 16, 40] {
            var stream: MaskedTraceStream = .init(masker: masker)
            var emitted: String = ""
            var index: String.Index = text.startIndex
            while index < text.endIndex {
                let next: String.Index = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex)
                    ?? text.endIndex
                emitted += stream.append(String(text[index ..< next]))
                index = next
            }
            emitted += stream.flush()
            let plain: String = emitted.replacingOccurrences(of: "[MASKED]", with: "")
            #expect(plain == "tail-markerend", "chunk 大小 \(chunkSize) 時明文被動到了")
            #expect(!emitted.contains("synthetic"))
        }
    }

    /// 強制放行之後押住的尾巴仍是秘密的一部分，`flush` 不得把它原樣吐出來。
    @Test
    func `forced release does not leak the held back tail`() {
        let secret: String = String(repeating: "s3cr3t-", count: 4)
        var stream: MaskedTraceStream = .init(masker: .init(maskedValues: [secret]))
        var emitted: String = ""
        for _ in 0 ..< 1000 {
            emitted += stream.append(secret)
        }
        emitted += stream.flush()
        #expect(!emitted.contains("s3cr3t"))
    }
}

/// 秘密不得因為某個人順手印了一個容器就外流。
private final class SecretRedactionTests {

    /// `TraceMasker` 的四條輸出路徑都只給數量。
    @Test
    func `masker never prints its phrases`() {
        let masker: TraceMasker = .init(maskedValues: ["synthetic-secret-value"])
        var dumped: String = ""
        dump(masker, to: &dumped)
        for rendered in ["\(masker)", String(describing: masker), String(reflecting: masker), dumped] {
            #expect(!rendered.contains("synthetic-secret-value"))
        }
    }

    /// `JobVariable` 不論有沒有標 masked 都不印值——旗標只是站台的判斷，不是唯一的秘密來源。
    @Test
    func `variable never prints its value`() {
        let plain: JobVariable = .init(key: "PLAIN", value: "synthetic-plain-value")
        let secret: JobVariable = .init(key: "SECRET", value: "synthetic-secret-value", masked: true)
        for variable in [plain, secret] {
            var dumped: String = ""
            dump(variable, to: &dumped)
            #expect(!"\(variable)".contains("synthetic"))
            #expect(!String(reflecting: variable).contains("synthetic"))
            #expect(!dumped.contains("synthetic"))
            #expect("\(variable)".contains(variable.key))
        }
    }

    /// `GitInfo` 印出來的網址不得帶 userinfo——站台慣例會把 job token 放在那裡。
    @Test
    func `git info never prints embedded credentials`() {
        let info: GitInfo = .init(
            repoURL: "https://gitlab-ci-token:synthetic-job-token@example.invalid/group/app.git",
            ref: "main",
            sha: "0123456789abcdef"
        )
        var dumped: String = ""
        dump(info, to: &dumped)
        for rendered in ["\(info)", String(reflecting: info), dumped] {
            #expect(!rendered.contains("synthetic-job-token"))
            #expect(rendered.contains("example.invalid/group/app.git"))
        }
    }

    /// userinfo 抹除的四個容易寫錯的形狀。
    @Test
    func `user info stripping handles the awkward shapes`() {
        let cases: [(String, String)] = [
            // 沒有 scheme（scp 式寫法）也要抹掉。
            ("gitlab-ci-token:TOKENVALUE@host/g/a.git", "***@host/g/a.git"),
            // 密碼含未編碼的 `@`：取最後一個，否則尾段會留下來。
            ("https://user:TOK@ENVALUE@host/g/a.git", "https://***@host/g/a.git"),
            // `@` 在 path 裡是正常的，不得動到。
            ("https://host/group/repo@v1.git", "https://host/group/repo@v1.git"),
            // 沒有 userinfo 就原樣回。
            ("https://host:8443/g/a.git", "https://host:8443/g/a.git"),
        ]
        for (input, expected) in cases {
            let info: GitInfo = .init(repoURL: input, ref: "main", sha: "abc")
            #expect("\(info)".contains(expected), "輸入 \(input) 的抹除結果不符")
            #expect(!"\(info)".contains("TOKENVALUE"))
            #expect(!"\(info)".contains("ENVALUE"))
        }
    }

    /// `JobResponse` 印出來不得帶 token 或變數值。
    @Test
    func `job response never prints its token`() {
        let job: JobResponse = .init(
            id: 3,
            token: "synthetic-job-token",
            variables: [.init(key: "DEPLOY_KEY", value: "synthetic-secret-value", masked: true)]
        )
        var dumped: String = ""
        dump(job, to: &dumped)
        for rendered in ["\(job)", String(reflecting: job), dumped] {
            #expect(!rendered.contains("synthetic-job-token"))
            #expect(!rendered.contains("synthetic-secret-value"))
        }
    }

    /// `JobPlan` 印出來只給形狀。
    @Test
    func `plan never prints variable values or phrases`() {
        let job: JobResponse = .init(
            id: 5,
            token: "synthetic-job-token",
            variables: [.init(key: "DEPLOY_KEY", value: "synthetic-secret-value", masked: true)]
        )
        guard case let .accepted(plan) = JobAdmission.review(job) else {
            Issue.record("預期 accepted")
            return
        }
        var dumped: String = ""
        dump(plan, to: &dumped)
        for rendered in ["\(plan)", String(reflecting: plan), dumped] {
            #expect(!rendered.contains("synthetic-secret-value"))
            #expect(!rendered.contains("synthetic-job-token"))
        }
    }

    /// 迴圈設定的四條輸出路徑都不得帶出 runner token，網址裡的憑證同樣不得留下。
    ///
    /// 第四條路（包進外層型別後 `dump`）單獨列出來，是因為排查時真正會被印的是持有設定的
    /// 那一層——只驗裸型別的話，`CustomReflectable` 漏實作也照樣過。
    @Test
    func `polling configuration never prints the runner token`() {
        struct Holder {
            let configuration: JobPollingLoop.Configuration
        }
        let configuration: JobPollingLoop.Configuration = .init(
            host: "https://oauth2:synthetic-job-token@gitlab.example.invalid",
            runnerToken: "synthetic-runner-token",
            image: .alias("golden-xcode")
        )
        var dumped: String = ""
        dump(configuration, to: &dumped)
        var nested: String = ""
        dump(Holder(configuration: configuration), to: &nested)
        for rendered in ["\(configuration)", String(reflecting: configuration), dumped, nested] {
            #expect(!rendered.contains("synthetic-runner-token"))
            #expect(!rendered.contains("synthetic-job-token"))
            #expect(rendered.contains("<redacted>"))
            #expect(rendered.contains("gitlab.example.invalid"))
        }
    }
}
