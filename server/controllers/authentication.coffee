passport     = require 'passport'
randomstring = require 'randomstring'
request      = require 'request-json'
async        = require 'async'
jwt          = require 'jsonwebtoken'

User         = require '../models/user'
Instance     = require '../models/instance'
helpers      = require '../lib/helpers'
timezones    = require '../lib/timezones'
localization = require '../lib/localization_manager'
passwordKeys = require '../lib/password_keys'
otpManager   = require '../lib/2fa_manager'

# hardcoded onboarding steps order and slug names
ONBOARDING_STEPS = [
    'welcome',
    'agreement',
    'password',
    'infos',
    'accounts',
    'ending'
]

getEnv = (callback) ->
    User.getUsername (err, username) ->
        return callback err if err

        otpManager.getAuthType (err, otp) ->
            return callback err if err

            env =
                username: username
                otp:      !!otp
                apps:     Object.keys require('../lib/router').getRoutes()

            callback null, env

verifyRegistrationToken = (token, tokenSalt, callback) ->
    User.getRegistrationToken (err, tokenData) ->
        return callback err if err

        if !tokenData.token or !tokenData.salt
            return callback null, false
        try
            decoded = jwt.verify(token, salt)
            # TODO: verify token options according to options stored in DS like
            # matchingOption1 = decoded.option1 is tokenData.option1
            matchingToken = token is tokenData.token
            matchingSalt = salt is tokenData.salt
            if matchingToken and matchingSalt
                # correct given token
                return callback null, true
            else
                return callback null, false
        catch err
            return callback err if err


module.exports.onboarding = (req, res, next) ->
    getEnv (err, env) ->
        if err
            error          = new Error "[Error to access cozy user] #{err.code}"
            error.status   = 500
            error.template = name: 'error'
            next error
        else
            # get user data
            User.first (err, userData) ->
                if err
                    error = new Error "[Error to access cozy user] #{err.code}"
                    error.status   = 500
                    error.template = name: 'error'
                    next error

                # According to steps changes
                if userData?.onboardedSteps is ONBOARDING_STEPS
                    res.redirect '/login'
                else
                    if userData
                        hasValidInfos = User.checkInfos userData
                        env.hasValidInfos = hasValidInfos
                    localization.setLocale req.headers['accept-language']
                    res.render 'index', {env: env, onBoarding: true}


# Save unauthenticated user document according to token existence and validity
# Expected request body format (? means optionnal)
# ?password
# ?allowStats
# ?CGUaccepted
# onboardedSteps
# token
# tokenSalt
module.exports.saveUnauthenticatedUser = (req, res, next) ->
    requestData = req.body

    token = requestData.token
    tokenSalt = requestData.tokenSalt
    verifyRegistrationToken token tokenSalt (err, isValid) ->
        if err
            error = new Error "[Error decoding registration token] #{err.code}"
            error.status   = 500
            error.template = name: 'error'
            next error
        if isValid
            userToSave = {}
            dataErrors = {}
            # grab data from the request body
            if requestData.password
                hash = helpers.cryptPassword req.body.password
                userToSave.password = hash.hash
                userToSave.salt = hash.salt
                passwdValidationError =
                    User.validatePassword requestData.password
                if passwdValidationError
                    dataErrors.password = localization.t 'password too short'
            if requestData.allowStats
                userToSave.allow_stats = requestData.allowStats
            if requestData.CGUaccepted
                userToSave.CGUaccepted = requestData.CGUaccepted
            # if password step done, reset token data
            if requestData.stepSlug = "password"
                userToSave.token = ""
                userToSave.salt = ""
            # onboarded steps update
            userToSave.onboardedSteps = requestData.onboardedSteps

            # other data
            userToSave.owner = true
            instanceData = locale: requestData.locale

        else
            error          = new Error "[Not authorized] 401"
            error.status   = 401
            error.template = name: 'error'
            next error

    unless Object.keys(dataErrors).length
        User.all (err, users) ->
            return next new Error err if err
            Instance.createOrUpdate instanceData, (err) ->
                return next new Error err if err

                if users.length
                    users[0].merge userToSave, (err) ->
                        return next new Error err if err
                        next()
                else
                    User.createNew userData, (err) ->
                        return next new Error err if err

                        # at first load, 'en' is the default locale
                        # we must change it now if it has changed
                        localization.setLocale requestData.locale
                        next()
    else
        error        = new Error 'Errors with data'
        error.errors = errors
        error.status = 400
        next error


# Save user document if authenticated
# Expected request body format (? means optionnal)
# ?username
# ?timezone
# ?email
# onboardedSteps
module.exports.saveAuthenticatedUser = (req, res, next) ->
    if not req.isAuthenticated()
        error        = new Error 'Not authorized 401'
        error.status = 401
        return next error

    requestData = req.body

    userToSave = {}
    errors = {}
    # grab data from the request body
    if requestData.username
        userToSave.public_name = requestData.username
    if requestData.email
        userToSave.email = requestData.email
    if requestData.timezone
        userToSave.timezone = requestData.timezone
    # if ending step done, user is registred
    if requestData.stepSlug = "ending"
        userToSave.activated = true
    # onboarded steps update
    validationErrors = User.validate userToSave
    userToSave.onboardedSteps = requestData.onboardedSteps

    unless Object.keys(validationErrors).length
        User.all (err, users) ->
            return next new Error err if err
            if users.length
                users[0].merge userToSave, (err) ->
                    return next new Error err if err
                    next()
    else
        error        = new Error 'Errors with validation'
        error.errors = validationErrors
        error.status = 400
        next error


module.exports.loginIndex = (req, res, next) ->
    getEnv (err, env) ->
        if err
            next new Error err
        else
            return res.redirect '/register' unless env.username
            res.set 'X-Cozy-Login-Page', 'true'
            res.render 'index', env: env


module.exports.forgotPassword = (req, res, next) ->
    User.first (err, user) ->
        if err
            next new Error err

        else unless user
            err         = new Error 'No user registered.'
            err.status  = 400
            err.headers = 'Location': '/register/'
            next err

        else
            key = randomstring.generate()
            Instance.setResetKey key
            Instance.first (err, instance) ->
                return next err if err
                instance ?= domain: 'domain.not.set'
                helpers.sendResetEmail instance, user, key, (err, result) ->
                    return next new Error 'Email cannot be sent' if err
                    res.sendStatus 204


module.exports.resetPasswordIndex = (req, res, next) ->
    getEnv (err, env) ->
        if err
            next new Error err
        else
            if Instance.getResetKey() is req.params.key
                res.render 'index', env: env
            else
                res.redirect '/'


module.exports.resetPassword = (req, res, next) ->
    key = req.params.key
    newPassword = req.body.password

    User.first (err, user) ->

        if err? then next new Error err

        else if not user?
            err = new Error 'reset error no user'
            err.status = 400
            err.headers = 'Location': '/register/'
            next err

        else

            if Instance.getResetKey() is req.params.key
                validationErrors = User.validatePassword newPassword

                unless Object.keys(validationErrors).length
                    data = password: helpers.cryptPassword(newPassword).hash
                    user.merge data, (err) ->
                        if err? then next new Error err
                        else
                            Instance.resetKey = null
                            passwordKeys.resetKeys newPassword, (err) ->

                                if err? then next new Error err
                                else
                                    passport.currentUser = null
                                    res.sendStatus 204

                else
                    error = new Error 'Errors in validation'
                    error.errors = validationErrors
                    error.status = 400
                    next error

            else
                error = new Error 'reset error invalid key'
                error.status = 400
                next error


module.exports.logout = (req, res) ->
    req.logout()
    res.sendStatus 204


module.exports.authenticated = (req, res) ->
    res.status(200).send isAuthenticated: req.isAuthenticated()
