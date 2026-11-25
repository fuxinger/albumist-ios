import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// How the covers lie (draft E3): the main cover upright in the middle and on top, the others
/// turned a little to each side behind it, a white edge and a soft shadow (drawn by the app).
@Suite("Result cover fan")
struct ResultCoverFanTests {
    /// One slot per cover, the main cover first, upright and on top.
    @Test func theMainCoverIsInTheMiddleAndOnTop() {
        for count in [1, 2, 3, 5] {
            let slots = ResultCoverFan.slots(count)
            #expect(slots.count == count)
            let main = slots[0]
            #expect(slots.dropFirst().allSatisfy { $0.layer < main.layer }, "\(count)")
            if count != 2 {
                #expect(main.angle == 0 && main.x == 0 && main.y == 0, "\(count)")
            }
        }
        // As in the draft: five covers turned 7° and 14° to each side.
        #expect(ResultCoverFan.slots(5).map(\.angle) == [0, -7, 7, -14, 14])
        // Four are laid as three.
        #expect(ResultCoverFan.count(4) == 3)
        #expect(ResultCoverFan.count(7) == 5)
        #expect(ResultCoverFan.slots(4) == ResultCoverFan.slots(3))
    }

    /// The covers lie down from the back to the front: the main cover last.
    @Test func theMainCoverLiesDownLast() {
        for count in [1, 2, 3, 5] {
            let order = ResultCoverFan.layingOrder(count)
            #expect(Set(order) == Set(0..<count))
            #expect(order.last == 0, "\(count): \(order)")
            let layers = order.map { ResultCoverFan.slots(count)[$0].layer }
            #expect(layers == layers.sorted(), "\(count): \(layers)")
        }
    }

    /// The fan is balanced around the middle of the screen.
    @Test func theFanIsBalanced() {
        for count in [1, 3, 5] {
            let box = ResultCoverFan.bounds(count)
            #expect(abs(box.minX + box.maxX) < 0.001, "\(count): \(box)")
        }
        let pair = ResultCoverFan.bounds(2)
        #expect(abs(pair.minX + pair.maxX) < 8, "\(pair)")
    }

    /// The success tap comes as the main cover lies down: the covers one after another, the main
    /// cover last, at most 0.74 s after the moment starts (five covers), 0.35 s with Reduce Motion,
    /// at once with the symbol. The screen lets the tap go after `successDeadline` whatever happens
    /// (review E of design wave 2, finding 1: it waited for Photos without a limit).
    @Test func theMainCoverLiesWithinTheDeadline() {
        #expect(ResultCoverFan.successDeadline == 1.5)
        for count in 0...7 {
            for calm in [false, true] {
                let settle = ResultCoverFan.settleTime(count: count, calm: calm)
                #expect(settle >= 0 && settle < ResultCoverFan.successDeadline, "\(count), calm \(calm): \(settle)")
            }
        }
        #expect(ResultCoverFan.settleTime(count: 0, calm: false) == 0, "the symbol: the tap at once")
        #expect(ResultCoverFan.settleTime(count: 0, calm: true) == 0)
        #expect(abs(ResultCoverFan.settleTime(count: 5, calm: false) - (4 * ResultCoverFan.layingStep + ResultCoverFan.lastFall)) < 1e-9)
        #expect(ResultCoverFan.settleTime(count: 1, calm: false) == ResultCoverFan.lastFall)
        #expect(ResultCoverFan.settleTime(count: 5, calm: true) == ResultCoverFan.fadeIn)
        // Four lie as three.
        #expect(ResultCoverFan.settleTime(count: 4, calm: false) == ResultCoverFan.settleTime(count: 3, calm: false))
    }

    /// Five covers fit across a 6.1" iPhone at their full size; on the 4.7" iPhone they get a
    /// little smaller, and where the screen is short they shrink, but never below six tenths:
    /// below that the screen scrolls, and the buttons under the stack keep their room (review E,
    /// finding 8).
    @Test func theFanFitsTheScreen() {
        let five = ResultCoverFan.size(5)
        #expect(five.width > 343 && five.width <= 361, "\(five)")
        #expect(ResultCoverFan.scale(count: 5, width: 361, height: 1000) == 1)
        let small = ResultCoverFan.scale(count: 5, width: 343, height: 1000)
        #expect(small < 1 && small > 0.9)
        #expect(ResultCoverFan.scale(count: 3, width: 343, height: 100) < 1)
        #expect(ResultCoverFan.scale(count: 3, width: 343, height: 10) == ResultCoverFan.minimumScale)
        #expect(ResultCoverFan.minimumScale == 0.6)
        #expect(ResultCoverFan.scale(count: 5, width: 100, height: 100) == 0.6)
        // One cover is the card's own size.
        #expect(ResultCoverFan.size(1).width == ResultCoverFan.cardWidth)
        #expect(ResultCoverFan.size(1).height == ResultCoverFan.cardHeight)
    }

    /// Until the screen's room is measured the fan is laid out at its smallest size, so once the
    /// room is known it can only grow: the count and the buttons below it never jump up as the
    /// result comes (on the 4.7" iPhone it stays as it was laid out; review E2 of design wave 2,
    /// N7).
    @Test func theFanOnlyGrowsOnceTheRoomIsKnown() {
        for count in [1, 2, 3, 5] {
            let unknown = ResultCoverFan.scale(count: count, width: 361, height: nil)
            #expect(unknown == ResultCoverFan.minimumScale, "\(count)")
            for width in [100.0, 343, 361, 600] {
                #expect(ResultCoverFan.scale(count: count, width: width, height: nil) == unknown, "\(count), \(width)")
                for height in [0.0, 10, 100, 150, 200, 1000] {
                    #expect(ResultCoverFan.scale(count: count, width: width, height: height) >= unknown, "\(count), \(width), \(height)")
                }
            }
        }
        // The 4.7" iPhone at the default size: less room than five covers take at the smallest
        // size (review E2: 193 pt drawn, 116 pt at the smallest), so the fan stays as it was laid out.
        #expect(ResultCoverFan.scale(count: 5, width: 343, height: 110) == ResultCoverFan.minimumScale)
    }
}
