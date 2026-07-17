import Testing
import Libavcodec

struct MinimalBuildTests {

    @Test("dav1d AV1 decoder remains available")
    func dav1dAvailable() {
        #expect(avcodec_find_decoder_by_name("libdav1d") != nil)
    }

    @Test("Teletext decoder is not compiled")
    func teletextUnavailable() {
        #expect(avcodec_find_decoder_by_name("libzvbi_teletext") == nil)
    }

    @Test("Configure flags enforce the non-GPL minimal build")
    func configureFlags() {
        let configuration = String(cString: avcodec_configuration())

        #expect(configuration.contains("--disable-gpl"))
        #expect(configuration.contains("--disable-version3"))
        #expect(configuration.contains("--disable-nonfree"))
        #expect(configuration.contains("--disable-avfilter"))
        #expect(configuration.contains("--disable-libzimg"))
        #expect(configuration.contains("--disable-libzvbi"))
    }
}
