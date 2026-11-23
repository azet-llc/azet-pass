package io.azet.pass

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLinksTest {
    private val print = "AB:CD:EF:01"
    private fun links(relation: String, pkg: String, fp: String) =
        """[{"relation":["$relation"],"target":{"namespace":"android_app","package_name":"$pkg","sha256_cert_fingerprints":["$fp"]}}]"""

    @Test fun `a site that names the app and its certificate links it`() {
        assertTrue(AppLinks.linkNames(links("delegate_permission/common.get_login_creds", "com.shop.app", "ab:cd:ef:01"), "com.shop.app", print))
        assertTrue(AppLinks.linkNames(links("delegate_permission/common.handle_all_urls", "com.shop.app", print), "com.shop.app", print))
    }

    @Test fun `another package, another certificate or another relation does not`() {
        assertFalse(AppLinks.linkNames(links("delegate_permission/common.get_login_creds", "com.evil.app", print), "com.shop.app", print))
        assertFalse(AppLinks.linkNames(links("delegate_permission/common.get_login_creds", "com.shop.app", "00:11"), "com.shop.app", print))
        assertFalse(AppLinks.linkNames(links("delegate_permission/common.use_as_origin", "com.shop.app", print), "com.shop.app", print))
        assertFalse(AppLinks.linkNames("not json", "com.shop.app", print))
    }
}
