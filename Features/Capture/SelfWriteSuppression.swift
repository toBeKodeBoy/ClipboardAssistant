import Foundation

/**
 * 本应用写回剪切板后的短时抑制。
 *
 * 写之前生成递增记号，并记下即将写入的哈希和负载摘要。写入完成后记号保留 1 秒。
 * 这 1 秒内，计数不小于当次 changeCount 的变化，只要去重哈希相同，或读回内容仍含有写下的负载，就跳过。
 * 系统合并补上纯文本或另一种图片编码时，去重哈希会变，但原负载还在，因此也跳过。
 * 未完成写入的记号不抑制。和写下的负载没有交集的新内容仍然入库。
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
        /** 即将写入或已经写入的去重哈希。 */
        var hash: String
        /** 写下的负载摘要。读回内容只要还含有其中之一，就视为同一次写入。 */
        var digests: Set<String>
        /** begin 的时间。超过 1 秒仍未 finish 的记号会被丢掉。 */
        var startedAt: Date
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
     * 在写剪切板之前记下哈希和负载摘要。
     *
     * 返回的记号要在写入完成后交给 finish。只调用 begin 不会抑制采集。
     *
     * @param hash 即将写入的去重哈希
     * @param digests 即将写入的负载摘要。为空时只按 hash 比较
     * @param now 开始时间，未 finish 的记号从这一刻起保留 1 秒
     * @return 本次写入的递增记号
     */
    mutating func begin(hash: String, digests: Set<String> = [], now: Date = Date()) -> UInt64 {
        nextToken += 1
        let token = nextToken
        marks.append(Mark(
            token: token,
            hash: hash,
            digests: digests,
            startedAt: now,
            changeCount: nil,
            expiresAt: nil
        ))
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
     * 丢掉已经到期的记号，以及开始后超过 1 秒仍未完成的记号。
     *
     * 采集在隐私或本应用判断处提前返回时也要调用，否则这些记号不会被收走。
     *
     * @param now 当前时间
     */
    mutating func prune(now: Date) {
        marks.removeAll { mark in
            if let expiresAt = mark.expiresAt {
                return now >= expiresAt
            }
            return now.timeIntervalSince(mark.startedAt) >= 1
        }
    }

    /**
     * 判断这次变化是不是仍在窗口内的自身写入。
     *
     * 先丢掉已经到期的记号。当次计数和之后的计数，去重哈希相同，或读回摘要里还含有写下的哈希或负载，就跳过。
     * 更早的计数不跳过，避免写之前已经开始的采集被误伤。满 1 秒返回 false。
     *
     * @param changeCount 本次观察到的 changeCount
     * @param hash 本次采集算出的去重哈希
     * @param digests 本次读回的负载摘要，包含原类型和系统补上的类型
     * @param now 观察时间
     * @return 应丢弃这次采集时返回 true
     */
    mutating func shouldIgnore(changeCount: Int, hash: String, digests: Set<String> = [], now: Date) -> Bool {
        prune(now: now)
        return marks.contains { mark in
            guard let recorded = mark.changeCount, mark.expiresAt != nil else { return false }
            guard changeCount >= recorded else { return false }
            if hash == mark.hash || digests.contains(mark.hash) || mark.digests.contains(hash) {
                return true
            }
            return !mark.digests.isDisjoint(with: digests)
        }
    }
}
