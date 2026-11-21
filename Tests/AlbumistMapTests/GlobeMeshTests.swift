import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The fixed geometry of our own globe (`GlobeMesh`): the Earth's sphere with its image
/// coordinates, and the stars.
@Suite("Globe mesh")
struct GlobeMeshTests {
    @Test func theSphereCoversTheEarthWithItsImage() {
        let columns = 192, rows = 96
        let (vertices, indices) = GlobeMesh.sphere(longitudeSegments: columns, latitudeSegments: rows)
        let count = vertices.count / GlobeMesh.floatsPerSphereVertex
        #expect(vertices.count % GlobeMesh.floatsPerSphereVertex == 0 && count == (columns + 1) * (rows + 1))
        #expect(indices.count == 3 * columns * (2 * rows - 2))
        #expect(indices.allSatisfy { Int($0) < count })
        func position(_ i: Int) -> GlobeVector {
            let k = i * GlobeMesh.floatsPerSphereVertex
            return GlobeVector(Double(vertices[k]), Double(vertices[k + 1]), Double(vertices[k + 2]))
        }
        func uv(_ i: Int) -> (u: Double, v: Double) {
            let k = i * GlobeMesh.floatsPerSphereVertex
            return (Double(vertices[k + 3]), Double(vertices[k + 4]))
        }
        var offSphere = 0, wrongImage = 0
        for i in 0..<count {
            let p = position(i)
            if abs(p.length - 1) > 1e-6 { offSphere += 1 }
            // The image coordinate is the point's own: u = (lon + 180) / 360, v = (90 − lat) / 180.
            let (u, v) = uv(i)
            let c = p.coordinate
            if abs(v - (90 - c.latitude) / 180) > 1e-6 { wrongImage += 1 }
            if abs(c.latitude) < 89.9, abs(u - (c.longitude + 180) / 360) > 1e-6, abs(u - 1) > 1e-6, abs(u) > 1e-6 { wrongImage += 1 }
        }
        #expect(offSphere == 0 && wrongImage == 0)
        // The seam's vertices twice: the same place, u = 0 and u = 1.
        for row in 0...rows {
            let west = row * (columns + 1), east = west + columns
            #expect((position(west) - position(east)).length < 1e-6)
            #expect(uv(west).u == 0 && uv(east).u == 1)
        }
        // Every triangle has an area and turns counter-clockwise seen from outside.
        var flat = 0, inward = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = position(Int(indices[t])), b = position(Int(indices[t + 1])), c = position(Int(indices[t + 2]))
            let normal = (b - a).cross(c - a)
            if normal.length < 1e-9 { flat += 1 }
            if normal.dot(a + b + c) <= 0 { inward += 1 }
        }
        #expect(flat == 0 && inward == 0)
    }

    @Test func theSphereNeedsSomeSegments() {
        let (vertices, indices) = GlobeMesh.sphere(longitudeSegments: 0, latitudeSegments: -4)
        #expect(vertices.count == 4 * 3 * GlobeMesh.floatsPerSphereVertex)
        #expect(indices.count == 3 * 3 * 2)
        #expect(vertices.allSatisfy { $0.isFinite })
    }

    @Test func theStarsAreFixedAndSpreadOverTheSky() {
        let stars = GlobeMesh.stars(count: 6_000)
        #expect(stars.count == 6_000 * GlobeMesh.floatsPerStar)
        #expect(GlobeMesh.stars(count: 6_000) == stars)
        #expect(GlobeMesh.stars(count: 6_000, seed: 7) != stars)
        var north = 0, bright = 0
        for i in 0..<6_000 {
            let k = i * GlobeMesh.floatsPerStar
            let direction = GlobeVector(Double(stars[k]), Double(stars[k + 1]), Double(stars[k + 2]))
            #expect(abs(direction.length - 1) < 1e-5)
            let brightness = stars[k + 3]
            #expect(brightness > 0 && brightness <= 1)
            if direction.y > 0 { north += 1 }
            if brightness > 0.5 { bright += 1 }
        }
        // Even over the sky; most faint, a few bright.
        #expect(abs(north - 3_000) < 200)
        #expect(bright > 30 && bright < 1_000)
        #expect(GlobeMesh.stars(count: 0).isEmpty && GlobeMesh.stars(count: -5).isEmpty)
    }
}
