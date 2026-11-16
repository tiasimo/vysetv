package com.vyse.vyse_tv

import androidx.core.content.FileProvider

/**
 * Lets Android's installer read the update VyseTV downloaded (its own cache/updates folder, and
 * nothing else: res/xml/update_paths.xml). A class of its own so it never clashes with a
 * FileProvider some plugin declares.
 */
class UpdateFileProvider : FileProvider()
