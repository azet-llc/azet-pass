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

class RootedTest {
    @Test fun `test keys or a su program mark a rooted phone`() {
        assertTrue(deviceRooted("release-keys,test-keys") { false })
        assertTrue(deviceRooted("release-keys") { it == "/system/xbin/su" })
        assertFalse(deviceRooted("release-keys") { false })
    }
}

class SiteOfTest {
    @Test fun `the registered part of a host, never a shared ending`() {
        org.junit.Assert.assertEquals("bank.co.kr", siteOf("login.bank.co.kr"))
        org.junit.Assert.assertNotEquals(siteOf("evil.co.kr"), siteOf("bank.co.kr"))
        org.junit.Assert.assertNotEquals(siteOf("evil.github.io"), siteOf("victim.github.io"))
        org.junit.Assert.assertNotEquals(siteOf("evil.com.br"), siteOf("bank.com.br"))
        org.junit.Assert.assertEquals(siteOf("accounts.google.com"), siteOf("www.google.com"))
        org.junit.Assert.assertEquals("naver.com", siteOf("nid.naver.com"))
    }
}

class OtpLabelTest {
    @Test fun `issuer and account come from the link`() {
        org.junit.Assert.assertEquals("GitHub" to "me@x.com", otpLabel("otpauth://totp/GitHub:me%40x.com?secret=ABC&issuer=GitHub"))
        org.junit.Assert.assertEquals("Naver" to "kim", otpLabel("otpauth://totp/kim?secret=ABC&issuer=Naver"))
        org.junit.Assert.assertEquals("Shop" to "", otpLabel("otpauth://totp/Shop?secret=ABC"))
    }
}

class PersonalFillTest {
    @Test fun `card and address boxes are recognised from hints and autocomplete names`() {
        org.junit.Assert.assertEquals("cc-number", FormParser.extraKind(setOf("creditcardnumber"), ""))
        org.junit.Assert.assertEquals("cc-exp", FormParser.extraKind(emptySet(), "cc-exp"))
        org.junit.Assert.assertEquals("zip", FormParser.extraKind(setOf("postalcode"), ""))
        org.junit.Assert.assertEquals("name", FormParser.extraKind(setOf("name"), ""))
        org.junit.Assert.assertEquals("addr", FormParser.extraKind(setOf("street-address"), ""))
        org.junit.Assert.assertEquals("first", FormParser.extraKind(setOf("given-name"), ""))
        org.junit.Assert.assertNull(FormParser.extraKind(setOf("username"), "username"))
        org.junit.Assert.assertNull(FormParser.extraKind(setOf("password"), "current-password"))
    }
}
