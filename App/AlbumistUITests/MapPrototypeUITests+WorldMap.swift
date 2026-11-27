import XCTest

extension MapPrototypeUITests {
    /// The map for laypeople (26.11.2026): every pin answers a tap, a trip opens with one main
    /// button, the film shows a station (or the story a photo), and the sheet goes back to the
    /// trips. Pins depend on the demo library's trips and the camera, so each kind found is
    /// tapped and reported; the trip list in the sheet is the app's own and must work.
    func worldMap() {
        shot("w1-map")
        for kind in ["region", "country", "trip", "place", "group"] {
            let pin = page("worldmap.pin.\(kind)")
            if pin.waitForExistence(timeout: kind == "region" ? 5 : 1) && pin.isHittable {
                pin.tap()
                print("UI_STEP_OK map pin \(kind) tapped")
                _ = UITestWait.holds(timeout: 2, interval: 0.5) { self.page("worldmap.sheet.close").exists }
                if page("worldmap.sheet.close").exists { page("worldmap.sheet.close").tap() }
            } else {
                print("UI_STEP_MISSING map pin \(kind) (none on screen)")
            }
        }
        if page("worldmap.all").exists { page("worldmap.all").tap() }
        guard tap(page("worldmap.trip"), "map trip row", timeout: 15) else { return }
        guard UITestWait.appears(page("worldmap.sheet.close"), "trip sheet", timeout: 10) else { return }
        shot("w2-trip")
        if page("worldmap.play").exists {
            tap(page("worldmap.play"), "play trip")
            UITestWait.appears(page("worldmap.film.station"), "film shows a station", timeout: 15)
            shot("w3-film")
            tap(page("worldmap.film.close"), "close film")
        } else if page("worldmap.story").exists {
            tap(page("worldmap.story"), "photo story")
            UITestWait.appears(page("worldmap.story.close"), "photo story open", timeout: 10)
            shot("w3-story")
            tap(page("worldmap.story.close"), "close photo story")
        } else {
            XCTFail("The trip has no main button")
        }
        UITestWait.appears(page("worldmap.sheet.close"), "trip sheet again", timeout: 15)
        tap(page("worldmap.sheet.close"), "back to the trips")
        UITestWait.appears(page("worldmap.trip"), "trip list", timeout: 10)
    }
}
