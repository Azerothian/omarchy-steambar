"""The JavaScript steamctl.py sends to Steam: the chat's BBCode handling and
the player summary, run in the demo's stand-in client."""
import json
import unittest

import support
import demo
import steamctl


def js(expression):
    return demo.evaluate(expression)


@unittest.skipUnless(support.has_js(), "needs Node or Bun")
class Html(unittest.TestCase):
    """HTML_JS: a message as Qt StyledText."""

    @classmethod
    def setUpClass(cls):
        support.demo_account()

    def html(self, text):
        return js("(%s)(%s)" % (steamctl.HTML_JS, json.dumps(text)))

    def test_escapes_and_line_breaks(self):
        self.assertEqual(self.html('<b>"hi"</b> & \n bye'), "&lt;b&gt;&quot;hi&quot;&lt;/b&gt; &amp; <br> bye")

    def test_bare_links_leave_trailing_punctuation(self):
        self.assertEqual(self.html("see https://example.com/a)."),
                         'see <a href="https://example.com/a">https://example.com/a</a>).')

    def test_tagged_links(self):
        self.assertEqual(self.html("[url=https://x.org]the [b]site[/b][/url]"), '<a href="https://x.org">the site</a>')
        self.assertEqual(self.html("[url]https://x.org[/url]"), '<a href="https://x.org">https://x.org</a>')

    def test_only_web_and_steam_links_are_clickable(self):
        self.assertEqual(self.html("[url=javascript:alert(1)]x[/url]"), "x")
        self.assertIn('href="steam://run/620"', self.html("[url=steam://run/620]play[/url]"))

    def test_emoticons_and_stickers(self):
        self.assertIn("emoticon/steamhappy\" width=\"20\"", self.html("[emoticon]steamhappy[/emoticon]"))
        self.assertIn("sticker/Fire\" width=\"96\"", self.html('[sticker type="Fire"][/sticker]'))

    def test_formatting(self):
        self.assertEqual(self.html("[b]bold[/b] [i]it[/i]"), "<b>bold</b> <i>it</i>")

    def test_unknown_and_escaped_brackets_stay_as_typed(self):
        self.assertEqual(self.html("[brb] back soon"), "[brb] back soon")
        self.assertEqual(self.html("\\[b]not bold\\[/b]"), "[b]not bold[/b]")


@unittest.skipUnless(support.has_js(), "needs Node or Bun")
class Embeds(unittest.TestCase):
    """EMBEDS_JS: shared things lifted out of a message as cards."""

    @classmethod
    def setUpClass(cls):
        support.demo_account()

    def embeds(self, text):
        return js("(%s)(%s)" % (steamctl.EMBEDS_JS, json.dumps(text)))

    def card(self, text):
        out = self.embeds(text)
        self.assertEqual(len(out["cards"]), 1, out)
        return out["cards"][0]

    def test_store_link(self):
        c = self.card("[steamstore]https://store.steampowered.com/app/1145360/Hades_II/?x=1[/steamstore]")
        self.assertEqual((c["type"], c["appid"], c["name"]), ("store", 1145360, "Hades II"))

    def test_store_link_by_attribute(self):
        c = self.card('[steamstore app="620"][/steamstore]')
        self.assertEqual((c["appid"], c["url"]), (620, "https://store.steampowered.com/app/620"))

    def test_store_link_without_an_app_falls_back_to_a_tag_card(self):
        c = self.card("[steamstore]nothing[/steamstore]")
        self.assertEqual((c["type"], c["tag"], c["body"]), ("tag", "steamstore", "nothing"))

    def test_workshop_item(self):
        c = self.card('[publishedfile url="https://steamcommunity.com/f?id=1" title="Mod \\"X\\"" votes_up=5 '
                      'creator_appid=892970][/publishedfile]')
        self.assertEqual((c["type"], c["title"], c["votesUp"], c["appid"]), ("workshop", 'Mod "X"', 5, 892970))

    def test_images(self):
        c = self.card("[img src=https://i.example/a.png thumbnail_src=https://i.example/t.png width=949 height=10][/img]")
        self.assertEqual((c["src"], c["thumb"], c["width"]), ("https://i.example/a.png", "https://i.example/t.png", 949))
        self.assertEqual(self.card("[img]https://i.example/b.png[/img]")["thumb"], "https://i.example/b.png")

    def test_video_needs_https(self):
        self.assertEqual(self.card('[video src="https://v.example/a.mp4"][/video]')["type"], "video")
        self.assertEqual(self.embeds('[video src="http://v.example/a.mp4"][/video]')["cards"][0]["type"], "tag")

    def test_youtube_forms(self):
        for text in ("[youtube=https://youtu.be/dQw4w9WgXcQ][/youtube]",
                     "[youtube]https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1[/youtube]",
                     '[youtube v="dQw4w9WgXcQ"][/youtube]',
                     "[youtube]https://www.youtube.com/shorts/dQw4w9WgXcQ[/youtube]"):
            self.assertEqual(self.card(text)["id"], "dQw4w9WgXcQ", text)

    def test_link_preview(self):
        c = self.card('[og url="https://news.example/a" img="https://news.example/i.jpg" title="T" desc="D"]x[/og]')
        self.assertEqual((c["type"], c["title"], c["description"], c["preview"]),
                         ("link", "T", "D", "https://news.example/i.jpg"))
        self.assertEqual(self.card('[og url="https://n.example" img="http://n.example/i.jpg"][/og]')["preview"], "")

    def test_unknown_tags_become_cards_to_copy(self):
        c = self.card('[gameinvite appid=548430 message="Join"][/gameinvite]')
        self.assertEqual((c["type"], c["tag"]), ("tag", "gameinvite"))
        self.assertEqual(c["fields"], [["appid", "548430"], ["message", "Join"]])
        self.assertEqual(c["raw"], '[gameinvite appid=548430 message="Join"][/gameinvite]')
        self.assertEqual(self.card('[roomeffect type="confetti"]')["fields"], [["type", "confetti"]])

    def test_plain_brackets_and_formatting_stay(self):
        out = self.embeds("[brb] [b]back[/b] [url=https://x.org]x[/url]")
        self.assertEqual(out["cards"], [])
        self.assertEqual(out["rest"], "[brb] [b]back[/b] [url=https://x.org]x[/url]")


@unittest.skipUnless(support.has_js(), "needs Node or Bun")
class Persona(unittest.TestCase):
    """PERSONA_JS: a player as the widget shows them."""

    @classmethod
    def setUpClass(cls):
        support.demo_account()

    def of(self, friend):
        return js("(%s).of(%s)" % (steamctl.PERSONA_JS, json.dumps(friend)))

    def test_nickname_and_persona_name(self):
        p = self.of({"accountid": 5, "display_name": "Kes", "m_persona": {"m_strPlayerName": "Kestrel", "m_ePersonaState": 3}})
        self.assertEqual((p["name"], p["personaName"], p["state"]), ("Kes", "Kestrel", "away"))
        p = self.of({"accountid": 5, "m_persona": {"m_strPlayerName": "Same", "m_ePersonaState": 1}})
        self.assertEqual((p["name"], p["personaName"]), ("Same", ""))

    def test_falls_back_to_the_account_id(self):
        self.assertEqual(self.of({"accountid": 77})["name"], "77")

    def test_avatar_hash(self):
        self.assertEqual(self.of({"accountid": 1, "m_persona": {"m_strAvatarHash": "0" * 40}})["avatar"], "")
        self.assertEqual(self.of({"accountid": 1, "m_persona": {"m_strAvatarHash": "ab" * 20}})["avatar"],
                         "https://avatars.fastly.steamstatic.com/%s_medium.jpg" % ("ab" * 20))

    def test_in_game(self):
        p = self.of({"accountid": 1, "current_game_icon_url": "f" * 40,
                     "m_persona": {"m_ePersonaState": 1, "m_unGamePlayedAppID": 620}})
        self.assertEqual((p["state"], p["appid"], p["game"]), ("in-game", 620, "Portal 2"))
        self.assertEqual(p["gameIcon"], "https://cdn.fastly.steamstatic.com/steamcommunity/public/images/apps/620/%s.jpg" % ("f" * 40))

    def test_offline_is_never_in_game(self):
        p = self.of({"accountid": 1, "m_persona": {"m_ePersonaState": 0, "m_unGamePlayedAppID": 620}})
        self.assertEqual((p["state"], p["appid"], p["game"]), ("offline", 0, ""))

    def test_a_non_steam_game_by_its_name(self):
        p = self.of({"accountid": 1, "m_persona": {"m_ePersonaState": 1, "m_gameid": "123456789012",
                                                   "m_strGameExtraInfo": "Minecraft"}})
        self.assertEqual((p["state"], p["game"]), ("in-game", "Minecraft"))


if __name__ == "__main__":
    unittest.main()
