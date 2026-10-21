@testable import SystemCore
import XCTest

/// Recorded `docker ps --format '{{json .}}'` and `docker stats --no-stream --format '{{json .}}'` lines (Docker CLI
/// 27): parsing, compose grouping, unit conversion, and malformed lines; and `docker system df --format json`.
final class DockerOutputTests: XCTestCase {
    /// Recorded `docker system df --format json` (Docker CLI 27), one line per kind of object.
    static let systemDF = """
    {"Active":"2","Reclaimable":"2.064GB (61%)","Size":"3.37GB","TotalCount":"7","Type":"Images"}
    {"Active":"2","Reclaimable":"0B (0%)","Size":"1.09kB","TotalCount":"2","Type":"Containers"}
    {"Active":"1","Reclaimable":"0B (0%)","Size":"41.94MB","TotalCount":"1","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"512.3MB","Size":"512.3MB","TotalCount":"14","Type":"Build Cache"}
    """

    private let psOutput = """
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-10-19 09:12:44 +0200 CEST","ID":"3f2a9c1b7d4e","Image":"postgres:16","Labels":"com.docker.compose.config-hash=ab12,com.docker.compose.container-number=1,com.docker.compose.oneoff=False,com.docker.compose.project=shop,com.docker.compose.project.config_files=/Users/me/dev/shop/compose.yaml,com.docker.compose.service=db,com.docker.compose.version=2.29.7","LocalVolumes":"1","Mounts":"shop_pgdata","Names":"shop-db-1","Networks":"shop_default","Ports":"0.0.0.0:5432-\\u003e5432/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}
    {"Command":"\\"node server.js\\"","CreatedAt":"2026-10-19 09:12:45 +0200 CEST","ID":"8b1e0d6c5a2f","Image":"shop-web","Labels":"com.docker.compose.project.working_dir=/Users/me/dev/shop,com.docker.compose.project=shop,com.docker.compose.service=web","LocalVolumes":"0","Mounts":"","Names":"shop-web-1","Networks":"shop_default","Ports":"0.0.0.0:3000-\\u003e3000/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-10-20 08:01:02 +0200 CEST","ID":"c0ffee123456","Image":"redis:7","Labels":"maintainer=someone","LocalVolumes":"1","Mounts":"c9e1…","Names":"cache","Networks":"bridge","Ports":"6379/tcp","RunningFor":"5 minutes ago","Size":"0B","State":"running","Status":"Up 5 minutes"}
    {"Command":"\\"/bin/sh\\"","CreatedAt":"2026-10-20 08:03:00 +0200 CEST","ID":"a1b2c3d4e5f6","Image":"alpine","Labels":"com.docker.compose.project=blog","LocalVolumes":"0","Mounts":"","Names":"blog-app-1","Networks":"blog_default","Ports":"","RunningFor":"3 minutes ago","Size":"0B","State":"running","Status":"Up 3 minutes"}
    """

    private let statsOutput = """
    {"BlockIO":"7.43MB / 0B","CPUPerc":"0.52%","Container":"3f2a9c1b7d4e","ID":"3f2a9c1b7d4e","MemPerc":"0.81%","MemUsage":"63.5MiB / 7.654GiB","Name":"shop-db-1","NetIO":"1.2kB / 0B","PIDs":"7"}
    {"BlockIO":"0B / 0B","CPUPerc":"112.40%","Container":"8b1e0d6c5a2f","ID":"8b1e0d6c5a2f","MemPerc":"13.07%","MemUsage":"1.0GiB / 7.654GiB","Name":"shop-web-1","NetIO":"3.4MB / 1.1MB","PIDs":"23"}
    {"BlockIO":"0B / 0B","CPUPerc":"0.20%","Container":"c0ffee123456","ID":"c0ffee123456","MemPerc":"0.05%","MemUsage":"4.25MiB / 512MiB","Name":"cache","NetIO":"0B / 0B","PIDs":"5"}
    {"BlockIO":"--","CPUPerc":"--","Container":"a1b2c3d4e5f6","ID":"a1b2c3d4e5f6","MemPerc":"--","MemUsage":"-- / --","Name":"blog-app-1","NetIO":"--","PIDs":"--"}
    """

    func testRecordedLinesBecomeContainersGroupedByComposeProject() {
        let breakdown = ContainerBreakdown(listing: DockerOutput.listing(psOutput), stats: DockerOutput.stats(statsOutput))

        XCTAssertEqual(breakdown.projects.map(\.name), ["blog", "shop"])
        let shop = breakdown.projects[1]
        XCTAssertEqual(shop.containers.map(\.name), ["shop-db-1", "shop-web-1"])
        XCTAssertEqual(shop.containers[0].image, "postgres:16")
        XCTAssertEqual(shop.containers[0].memoryUsed, 66_584_576, "63.5 MiB")
        XCTAssertEqual(shop.containers[0].memoryLimit, 8_218_419_921, "7.654 GiB, rounded to a byte")
        XCTAssertEqual(shop.containers[1].cpuPercent, 112.4, "a container may use more than one core")
        XCTAssertEqual(shop.totals.memoryUsed.sum, 66_584_576 + 1_073_741_824)
        XCTAssertEqual(try XCTUnwrap(shop.totals.cpuPercent.sum), 112.92, accuracy: 1e-9)
        XCTAssertEqual(shop.totals.containerCount, 2)

        XCTAssertEqual(breakdown.standalone.map(\.name), ["cache"], "a container without the compose label stands alone")
        XCTAssertEqual(breakdown.standalone[0].memoryLimit, 536_870_912)

        let blog = breakdown.projects[0]
        XCTAssertNil(blog.containers[0].cpuPercent, "the CLI's -- placeholder is unmeasured, not zero")
        XCTAssertNil(blog.containers[0].memoryUsed)
        XCTAssertNil(blog.totals.memoryUsed.sum)
        XCTAssertEqual(blog.totals.memoryUsed.unmeasuredCount, 1)

        XCTAssertEqual(breakdown.totals.containerCount, 4)
        XCTAssertEqual(breakdown.totals.memoryUsed.measuredCount, 3)
        XCTAssertEqual(breakdown.totals.memoryUsed.unmeasuredCount, 1)
        XCTAssertEqual(breakdown.totals.memoryUsed.sum, 66_584_576 + 1_073_741_824 + 4_456_448)
        XCTAssertEqual(breakdown.skippedLines, 0)
        XCTAssertEqual(breakdown.unreadableValues, 0)
    }

    func testMalformedLinesAreSkippedAndCounted() {
        let stats = DockerOutput.stats("""
        {"CPUPerc":"1.00%","ID":"aaaaaaaaaaaa","MemUsage":"1MiB / 2GiB","Name":"a"}
        WARNING: Error loading config file: /Users/me/.docker/config.json: permission denied
        {"CPUPerc":"1.00%","MemUsage":"1MiB / 2GiB","Name":"no-id"}
        ["not", "an", "object"]
        {"CPUPerc":"lots","ID":"bbbbbbbbbbbb","MemUsage":"12 parsecs / 2GiB","Name":"b"}
        {"truncated":

        """)

        XCTAssertEqual(stats.rows.map(\.id), ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        XCTAssertEqual(stats.skippedLines, 4, "text, a row without an ID, an array, and a cut-off object; blank lines do not count")
        XCTAssertEqual(stats.unreadableValues, 2, "an unknown percent and an unknown unit are counted and left nil")
        XCTAssertNil(stats.rows[1].cpuPercent)
        XCTAssertNil(stats.rows[1].memoryUsed)
        XCTAssertEqual(stats.rows[1].memoryLimit, 2_147_483_648)
        XCTAssertFalse(stats.isUnparsable)

        let breakdown = ContainerBreakdown(listing: DockerOutput.listing("garbage\n"), stats: stats)
        XCTAssertEqual(breakdown.skippedLines, 5)
        XCTAssertEqual(breakdown.unreadableValues, 2)
        XCTAssertEqual(breakdown.standalone.map(\.name), ["a", "b"], "stats rows without a listing are still containers")
    }

    func testAMemoryUsageThatIsNotUsedSlashLimitIsCountedOnce() {
        let stats = DockerOutput.stats("""
        {"CPUPerc":"1.00%","ID":"aaaaaaaaaaaa","MemUsage":123}
        {"CPUPerc":"1.00%","ID":"bbbbbbbbbbbb","MemUsage":"1MiB / 2GiB / 3GiB"}
        {"CPUPerc":"1.00%","ID":"cccccccccccc","MemUsage":"1MiB"}
        {"CPUPerc":"1.00%","ID":"dddddddddddd","MemUsage":"--"}
        {"CPUPerc":"1.00%","ID":"eeeeeeeeeeee"}
        {"CPUPerc":"--","ID":"ffffffffffff","MemUsage":"-- / --"}
        """)

        XCTAssertEqual(stats.rows.count, 6)
        XCTAssertEqual(stats.skippedLines, 0)
        XCTAssertEqual(stats.unreadableValues, 3, "a number, three halves, and one half are each one unreadable value")
        XCTAssertTrue(stats.rows.allSatisfy { $0.memoryUsed == nil && $0.memoryLimit == nil })
        XCTAssertEqual(stats.rows.map(\.cpuPercent), [1, 1, 1, 1, 1, nil])
    }

    func testOutputWithLinesButNoReadableRowIsUnparsable() {
        XCTAssertTrue(DockerOutput.listing("<html>proxy error</html>\n{}\n").isUnparsable)
        XCTAssertFalse(DockerOutput.listing("").isUnparsable, "no output is no running containers")
        XCTAssertFalse(DockerOutput.listing("\n\n").isUnparsable)
    }

    func testUnitsConvertToBytesAndPercent() {
        XCTAssertEqual(DockerOutput.bytes("0B"), 0)
        XCTAssertEqual(DockerOutput.bytes("512B"), 512)
        XCTAssertEqual(DockerOutput.bytes("1.5KiB"), 1_536)
        XCTAssertEqual(DockerOutput.bytes("63.5MiB"), 66_584_576)
        XCTAssertEqual(DockerOutput.bytes("2GiB"), 2_147_483_648)
        XCTAssertEqual(DockerOutput.bytes("1TiB"), 1_099_511_627_776)
        XCTAssertEqual(DockerOutput.bytes("7.43MB"), 7_430_000, "I/O columns use decimal units")
        XCTAssertEqual(DockerOutput.bytes("1.2kB"), 1_200)
        XCTAssertEqual(DockerOutput.bytes(" 3GB "), 3_000_000_000)
        XCTAssertNil(DockerOutput.bytes("12"), "a size needs a unit")
        XCTAssertNil(DockerOutput.bytes("MiB"))
        XCTAssertNil(DockerOutput.bytes("-1MiB"))
        XCTAssertNil(DockerOutput.bytes("1XB"))
        XCTAssertNil(DockerOutput.bytes("nanMiB"))
        XCTAssertNil(DockerOutput.bytes("99999999PiB"), "beyond 64 bits")

        XCTAssertEqual(DockerOutput.percent("0.52%"), 0.52)
        XCTAssertEqual(DockerOutput.percent("112.40%"), 112.4)
        XCTAssertNil(DockerOutput.percent("0.52"))
        XCTAssertNil(DockerOutput.percent("abc%"))
        XCTAssertNil(DockerOutput.percent("-3%"))
    }

    func testTheComposeProjectComesOnlyFromItsOwnLabel() {
        XCTAssertEqual(DockerOutput.composeProject(labels: "com.docker.compose.project.config_files=/x,com.docker.compose.project=shop"), "shop")
        XCTAssertNil(DockerOutput.composeProject(labels: "com.docker.compose.project.working_dir=/Users/me/shop"))
        XCTAssertNil(DockerOutput.composeProject(labels: "com.docker.compose.project="))
        XCTAssertNil(DockerOutput.composeProject(labels: ""))
    }

    func testStatsJoinTheirListingByIDPrefixAndNeverAcrossConflictingIDs() {
        let listing = DockerOutput.listing("""
        {"ID":"3f2a9c1b7d4e","Names":"db,alias","Labels":""}
        {"ID":"","Names":"no-id","Labels":""}
        {"ID":"777777777777","Names":"renamed","Labels":""}
        """)
        let stats = DockerOutput.stats("""
        {"ID":"3f2a9c1b7d4e5b6a7c8d9e0f","Name":"db","CPUPerc":"1.00%","MemUsage":"1MiB / 1GiB"}
        {"ID":"999999999999","Name":"renamed","CPUPerc":"2.00%","MemUsage":"2MiB / 1GiB"}
        """)

        let breakdown = ContainerBreakdown(listing: listing, stats: stats)

        XCTAssertEqual(listing.skippedLines, 1, "a listing without an ID is skipped")
        XCTAssertEqual(breakdown.standalone.map(\.name), ["db", "renamed", "renamed"], "the first of several names is shown")
        XCTAssertEqual(breakdown.standalone.map(\.id), ["3f2a9c1b7d4e", "777777777777", "999999999999"])
        XCTAssertEqual(breakdown.standalone.map(\.cpuPercent), [1, nil, 2],
                       "a full ID matches its short form; a container recreated under the same name is another container")
        XCTAssertEqual(breakdown.totals.containerCount, 3)
    }

    func testSystemDFGivesTheImagesRow() {
        XCTAssertEqual(DockerOutput.imageSpace(Self.systemDF),
                       DockerImageSpace(count: 7, active: 2, size: 3_370_000_000, reclaimable: 2_064_000_000))
        // Only the Images row counts, wherever it is, and a count may be a number.
        let reordered = """
        {"Active":"0","Reclaimable":"1GB","Size":"1GB","TotalCount":"3","Type":"Build Cache"}
        not json
        {"Active":0,"Reclaimable":"0B (0%)","Size":"12.5MB","TotalCount":1,"Type":"Images"}
        """
        XCTAssertEqual(DockerOutput.imageSpace(reordered), DockerImageSpace(count: 1, active: 0, size: 12_500_000, reclaimable: 0))
    }

    func testSystemDFWithoutAReadableImagesRowIsNothing() {
        XCTAssertNil(DockerOutput.imageSpace(""))
        XCTAssertNil(DockerOutput.imageSpace(#"{"Type":"Containers","Size":"1GB","Reclaimable":"0B"}"#))
        XCTAssertNil(DockerOutput.imageSpace(#"{"Type":"Images","Size":"lots","Reclaimable":"some"}"#))
        // One readable size is kept, the other is unknown.
        XCTAssertEqual(DockerOutput.imageSpace(#"{"Type":"Images","Size":"2GB","Reclaimable":"--"}"#),
                       DockerImageSpace(count: nil, active: nil, size: 2_000_000_000, reclaimable: nil))
    }
}
