import Foundation

/**
 * 本应用写回剪切板后的短时抑制。
 *
 * 写之前生成递增记号并记下即将写入的哈希。写入完成后记号保留 1 秒。
 * 这 1 秒内，计数不小于当次 changeCount 且哈希相同的变化都跳过，包括系统合并产生的下一次变化。
 * 未完成写入的记号不抑制。哈希不同仍然入库。
 *
 * @author toBeKodeBoy
 * @date 2026/11/04
 */
struct SelfWriteSuppression {
    /**
     * 一次尚未过期的自身写入。
     *
     * expiresAt 为空表示还没写完，不能用来跳过采集。
     */
    private struct Mark {
        /** 写之前发出的递增记号。 */
        var token: UInt64
        /** 即将写入或已经写入的内容哈希。 */
        var hash: String
        /** 写入完成后的 changeCount。未完成时为空。 */
        var changeCount: Int?
        /** 窗口结束时间。满这一刻起不再抑制。 */
        var expiresAt: Date?
    }

    /** 下一个记号。从 1 开始，0 留给没有监视器的调用方。 */
    private var nextToken: UInt64 = 0
    /** 尚未过期，以及已开始但尚未完成的写入。 */
    private var marks: [Mark] = []

    /**
     * 在写剪切板之前记下哈希。
     *
     * 返回的记号要在写入完成后交给 finish。只调用 begin 不会抑制采集。
     *
     * @param hash 即将写入的内容哈希
     * @return 本次写入的递增记号
     */
    mutating func begin(hash: String) -> UInt64 {
        nextToken += 1
        let token = nextToken
        marks.append(Mark(token: token, hash: hash, changeCount: nil, expiresAt: nil))
        return token
    }

    /**
     * 写入完成后打开 1 秒窗口。
     *
     * 未知记号被忽略。期限从 now 起算，到 now + 1 秒为止，不含结束时刻。
     *
     * @param token begin 返回的记号
     * @param changeCount 写入后的 changeCount
     * @param now 写入完成的时间
     */
    mutating func finish(token: UInt64, changeCount: Int, now: Date) {
        guard let index = marks.firstIndex(where: { $0.token == token }) else { return }
        marks[index].changeCount = changeCount
        marks[index].expiresAt = now.addingTimeInterval(1)
    }

    /**
     * 判断这次变化是不是仍在窗口内的自身写入。
     *
     * 先丢掉已经到期的记号。当次计数和之后的计数，只要哈希与某个未过期记号相同，就跳过。
     * 更早的计数不跳过，避免写之前已经开始的采集被误伤。满 1 秒返回 false。
     *
     * @param changeCount 本次观察到的 changeCount
     * @param hash 本次采集算出的内容哈希
     * @param now 观察时间
     * @return 应丢弃这次采集时返回 true
     */
    mutating func shouldIgnore(changeCount: Int, hash: String, now: Date) -> Bool {
        marks.removeAll { mark in
            guard let expiresAt = mark.expiresAt else { return false }
            return now >= expiresAt
        }
        return marks.contains { mark in
            guard let recorded = mark.changeCount, let expiresAt = mark.expiresAt else { return false }
            return now < expiresAt && mark.hash == hash && changeCount >= recorded
        }
    }
}
