# Docs Preview Renderer Fixture

This fixture is a small API documentation preview source tree. The local
preview builder renders MDX headings to HTML anchors through
`packages/mdx-renderer/src/headingSlug.ts`.

The focused slugger regression is intentionally failing in the trusted release
commit until the duplicate-heading suffix logic is fixed.
