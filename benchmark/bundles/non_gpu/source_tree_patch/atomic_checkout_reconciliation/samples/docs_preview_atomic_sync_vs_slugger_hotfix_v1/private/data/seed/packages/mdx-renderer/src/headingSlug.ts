"use strict";

function normalizeHeading(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/`([^`]+)`/g, "$1")
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function createHeadingSlugger() {
  const seen = new Set();
  return function headingSlug(text) {
    const base = normalizeHeading(text) || "section";
    if (!seen.has(base)) {
      seen.add(base);
      return base;
    }
    return `${base}-2`;
  };
}

module.exports = {
  createHeadingSlugger,
  normalizeHeading,
};
