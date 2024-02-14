'use strict'

const branch = process.env.CI_COMMIT_BRANCH
const host = process.env.CI_SERVER_HOST

const publishPlugins = [
   
]

module.exports = {
    ci: true,
    branches: [
        "master",
        "develop",
        { name: "release/*", prerelease: "rc" }
    ],
    repositoryUrl: `git@${host}:artforintrovert/mobileApp.git`,
    tagFormat: "v${version}",
    plugins: [
        [
            "@semantic-release/commit-analyzer",
            {
                "preset": "angular",
                "releaseRules": [
                    { type: "feat", release: "minor" },
                    { type: "patch", release: "patch" },
                    { type: "fix", release: "patch", },
                    { type: "style", release: "patch", },
                    { "scope": "no-release", "release": false }
                ]
            }
        ],
        [
            "@semantic-release/release-notes-generator",
            require('./.changelog')
        ],
        [
            "@semantic-release/changelog",
            {
                changelogFile: "CHANGELOG.md",
                changelogTitle: "# CHANGELOG"
            }
        ],
    
        [
            "@semantic-release/gitlab", {
                successComment: false,
                failComment: false,
                failTitle: false,
            }
        ],
        [
            '@semantic-release/git',
            {
                assets: ['CHANGELOG.md'],
                message: 'chore(release): ${nextRelease.version} [release]\n\n${nextRelease.notes}',
            },
        ],
    ]
}
