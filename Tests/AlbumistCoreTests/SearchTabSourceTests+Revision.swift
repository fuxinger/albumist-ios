import Foundation
import Testing
import AlbumistTestSupport

/// The revision the search page's answer keys on (review Q1 of H14's round 3; `SearchAnswer`,
/// `SearchTabSourceTests.comingBackToTheTabDoesNotSearchAgain`): it counts every change of what a
/// search reads, not only the photos' facts, so the tab chosen again searches after an ignored
/// photo, a deleted album or a place's new name, and only then.
extension SearchTabSourceTests {
    static let model = "App/Albumist/Model/AppModel.swift"
    static let mark = "// Design W3 H14"

    /// What a search reads, from its own code: the index is made of the facts, the albums, the
    /// names of places and the home (`searchIndex()`; the names are compared at every search and
    /// empty the index when they differ); a search for a state ("Unsortiert") also reads the
    /// photos' states, the settings' primary areas and the part of the library (`plainSearch`);
    /// and the parse reads the day ("heute", `QueryParser.now`). The revision is raised where the
    /// index is emptied (`resetSearchIndex`: the facts, the albums, the home, the names), where the
    /// library's inputs change (`libraryInputsChanged`: the facts, the states, the settings, the
    /// part), and at a new day or clock (`timeChanged`). Three marked lines raise it, nothing
    /// else sets it, and it is not observed (no view draws again for it). The page asks it through
    /// `searchRevisionNow()`, which asks for the index first, so a place's name typed since is
    /// compared and counted before the revision is read, whichever task of the page runs first.
    /// A new read in `searchIndex()` or `plainSearch` fails here until it is counted.
    @Test func theRevisionCountsEveryChangeOfWhatASearchReads() throws {
        let raw = try AppSource.read(Self.model)
        let model = try Self.code(Self.model)
        // Declared beside the index, not observed, and read only as the page asks.
        let declaration = "    @ObservationIgnored private var searchRevision = 0 \(Self.mark)"
        #expect(raw.contains("\n\(declaration)"), "\(declaration)")
        let now = "    func searchRevisionNow() async -> Int { _ = await searchIndex(); return searchRevision } \(Self.mark)"
        #expect(raw.contains("\n\(now)"), "\(now)")
        // Raised in three places, each a marked line of its own; set nowhere else.
        let raise = "searchRevision &+= 1"
        #expect(model.components(separatedBy: raise).count - 1 == 3, "raised elsewhere too")
        for line in raw.split(separator: "\n") where line.contains(raise) {
            #expect(line.hasPrefix("        \(raise) \(Self.mark)"), "unmarked: \(line)")
        }
        let squeezed = Self.squeezed(model)
        #expect(squeezed.components(separatedBy: "searchRevision=").count - 1 == 1, "the revision is set elsewhere than at its start")
        let reset = Self.squeezed(try Self.modelBody(["private func resetSearchIndex()"]))
        #expect(reset == "{searchIndexStore.invalidate()searchRevision&+=1}", "\(reset)")
        let inputs = Self.squeezed(try Self.modelBody(["private func libraryInputsChanged()"]))
        #expect(inputs == "{libraryInputs+=1searchRevision&+=1iflibraryBucketsShown&&!movingInLibrary{makeLibraryBuckets()}}", "\(inputs)")
        let time = Self.squeezed(try Self.modelBody(["func timeChanged()"]))
        #expect(time.hasPrefix("{searchRevision&+=1guardanalysis.isRunning,"), "raised only while a run is busy: \(time)")
        // Who empties the index and who changes the library's inputs: every input a search reads.
        for (input, call) in [("varfacts:[AssetFacts]=[]{didSet{", "libraryInputsChanged()"),
                              ("varfacts:[AssetFacts]=[]{didSet{", "resetSearchIndex()"),
                              ("varinventory=CollectionInventory(){didSet{", "resetSearchIndex()"),
                              ("private(set)varhomeSettings=HomeSettings(){didSet{", "ifhomeSettings!=oldValue{resetSearchIndex()}"),
                              ("varstates:[AssetID:AssetOrganizationState]=[:]{didSet{", "libraryInputsChanged()"),
                              ("varsettings=OrganizationSettings(){didSet{", "libraryInputsChanged()"),
                              ("varanalysisScope:OrganizationScope=.all{didSet{", "ifoldValue!=analysisScope{libraryInputsChanged()}")] {
            let didSet = try #require(Self.block(after: input, in: squeezed), "\(input) has no didSet")
            #expect(didSet.contains(call), "\(input) no longer calls \(call): \(didSet)")
        }
        // What a search reads, whole: a new read here needs its count above.
        let index = Self.squeezed(try Self.modelBody(["func searchIndex() async -> SearchIndex"]))
        #expect(index == "{letplaceNames=NamedPlace.resolve(titles:userTitles,settings:settings.frequentPlaces,suggestions:proposals)"
                + "ifplaceNames!=searchIndexPlaceNames{resetSearchIndex()searchIndexPlaceNames=placeNames}"
                + "returnawaitsearchIndexStore.index{letfacts=facts,inventory=inventory,home=homeSettings,placeNames=searchIndexPlaceNames"
                + "return{SearchIndex(facts:facts,inventory:inventory,namedPlaces:placeNames,home:home)}}}", "\(index)")
        let plain = Self.squeezed(try Self.modelBody(["private func plainSearch(_ query: String) async -> SearchResult"]))
        #expect(plain == "{letindex=awaitsearchIndex()letparsed=awaitTask.detached(priority:.userInitiated){index.parse(query)}.value"
                + "letwantsStatus=parsed.usesStatusletfacts=wantsStatus?self.facts:[],states=wantsStatus?self.states:[:]"
                + "letresolver=self.resolver,scope=analysisScopereturnawaitTask.detached(priority:.userInitiated){letstatuses=wantsStatus"
                + "?LibraryStatus.searchStatuses(facts:facts,states:states,resolver:resolver,scope:scope):[:]"
                + "returnSearchEngine().run(parsed,in:index,statuses:statuses)}.value}", "\(plain)")
        let resolver = Self.squeezed(try Self.modelBody(["var resolver: OrganizationStatusResolver"]))
        #expect(resolver == "{OrganizationStatusResolver(primaryAreas:settings.primaryAreas)}", "\(resolver)")
        // The day: iOS's significant time change (midnight too) reaches `timeChanged`.
        let app = Self.squeezed(try Self.code("App/Albumist/App/AlbumistApp.swift"))
        #expect(app.contains(".onReceive(NotificationCenter.default.publisher(for:UIApplication.significantTimeChangeNotification)){_inmodel.timeChanged()}"))
    }

    /// What the user does on the search page itself leaves its hits as they were before wave 3:
    /// "Ignorieren" in a hit's long press, "Widerrufen", "Als Album anlegen" and "Zu Album
    /// hinzufügen …" change what a search reads, but the page searches only in its task, whose id
    /// is the text, so the hits stay while the page is open (the photo ignored there stays among
    /// them, with "Widerrufen" below). A page that comes back (after the photo view, a preview on
    /// its stack, another tab) searches again when something changed; before wave 3 it searched
    /// again every time.
    @Test func whatIsDoneOnThePageLeavesItsHitsUntilItComesBack() throws {
        let view = Self.squeezed(try Self.code(Self.search))
        // The declaration and the task's two: the empty field and the answer.
        #expect(view.components(separatedBy: "result=").count - 1 == 3, "the hits are set outside the page's task: \(view)")
        #expect(view.contains("@Stateprivatevarresult=SearchResult()"), "\(view)")
        let task = try #require(view.range(of: ".task(id:query){"), "\(view)")
        let inTask = String(view[task.upperBound...])
        #expect(inTask.contains("result=SearchResult();answer.emptied()") && inTask.contains("result=found.beside(completions,for:text)"),
                "\(inTask)")
        #expect(view.components(separatedBy: "model.search(").count - 1 == 1, "\(view)")
        let perform = Self.squeezed(try Self.body(["struct SearchView", "private func perform("], in: Self.search))
        #expect(perform == "{switchaction{case.view:open(id,from:key)case.addToAlbum:addingToAlbum=[id]"
                + "case.ignore,.stopIgnoring,.removeFromSuggestion:break}}", "\(perform)")
    }

    /// The body of a declaration of `AppModel.swift`, comments blanked.
    static func modelBody(_ declarations: [String]) throws -> String {
        try Self.body(declarations, in: Self.model)
    }

    /// What stands between the "{" that `start` ends with and its matching "}" in `text`.
    static func block(after start: String, in text: String) -> String? {
        guard let open = text.range(of: start) else { return nil }
        var depth = 1
        var end = open.upperBound
        while end < text.endIndex {
            if text[end] == "{" { depth += 1 }
            if text[end] == "}" { depth -= 1 }
            if depth == 0 { return String(text[open.upperBound..<end]) }
            end = text.index(after: end)
        }
        return nil
    }
}
