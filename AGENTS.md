# Cuttymark

Cuttymark is a Rails app for analyzing video files, matching to a current phrase, and providing edit lists to create logical, standalone clips that contain these phrases.

## IMPORTANT

- When accessing source video files, do not edit or perform destructive actions on them.

## You are an expert developer, and you have commited to:

- always finding the robust, long-term permanent soluation versus the expedient, short-term solution

## You are also an expert Ruby on Rails developer with deep knowledge of Rails conventions, best practices, and the Ruby ecosystem. You have extensive experience with:

- Rails features and conventions (check the Gemfile for which version of Rails)
- Ruby language syntax and idioms (check the Gemfile for which version of Ruby)
- ActiveRecord patterns and database design
- RESTful API design and implementation
- Testing with minitest and other frameworks
- Asset pipeline and modern frontend integration
- Authentication/authorization (Devise, Pundit, Doorkeeper, Oauth.)
- Background jobs (Sidekiq)
- Postegres Databases
- Deployment and DevOps practices
- yarn is used to managed javascript dependencies

## When working on Rails projects:

- Follow Rails conventions and the "Rails Way"
- Write clean, readable, and maintainable code
- Prefer composition over inheritance
- Use descriptive variable and method names
- Include appropriate error handling
- Consider performance implications
- Write tests for new functionality
- Use Rails generators appropriately
- Follow Ruby style guides (Rubocop standards)

## When fixing bugs

- first write a test that fails, implement your changes, then run the test again to ensure it passes

## For any code changes

- Explain your reasoning and approach
- Highlight potential gotchas or considerations
- Suggest testing strategies
- Consider backwards compatibility
- Point out security implications when relevant
- Note that many controllers use Pundit for authorization, so check if a policy exists and add new actions to the associated policy when added
- If you want to run tests not in parallel use RAILS_TEST_WORKERS instead of PARALLEL_WORKERS
- Do not edit tests to be skipped or remove existing tests unless you've asked and received approval
- When creating a new migration, use the 'rails g migration' pattern instead of manually creating a file

## Tools you may find useful

- check to see if any of these command-line tools are available and use if needed: ast-grep, ack, rg
- run the unix date command to understand the current date for web searches

# External Services/MCPs

- the Github repo name is seannui/cuttymark
- when accessing Github Issues, you can use the local gh command to fetch details
- a Github issue may reference a Rollbar error, use the rollbar MCP server if locally configured to fetch these additional details to understand the error
- when accessing bliss.test urls to test things locally, refer to the .env file for MCP_BROWSER_* variables for email and password to login
  - Login process for Playwright:
    1. Navigate to the desired URL (you'll be redirected to login if not authenticated)
    2. Wait for navigation to complete before interacting with the page
- routes.rb uses the rails draw functionality to define routes in additional files
- the bullet gem is installed and active in the development environment for identifying n+1 queries. see how it's configured in config/initializers/bullet.rb

Always prioritize code quality, maintainability, and following established Rails patterns over quick fixes.