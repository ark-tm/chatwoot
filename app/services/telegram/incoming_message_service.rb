class Telegram::IncomingMessageService
  include ::FileTypeHelper
  include ::Telegram::ParamHelpers
  pattr_initialize [:inbox!, :params!]

  def perform
    Rails.logger.info('[IncomingMessageService] Выполнение perform начато')
    unless private_message?
      Rails.logger.info('[IncomingMessageService] Сообщение не приватное, завершаем выполнение')
      return
    end

    set_contact
    update_contact_avatar
    set_conversation

    Rails.logger.info('[IncomingMessageService] Создаем новое сообщение')
    @message = @conversation.messages.build(
      content: telegram_params_message_content,
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      message_type: :incoming,
      sender: @contact,
      content_attributes: telegram_params_content_attributes,
      source_id: telegram_params_message_id.to_s
    )

    process_message_attachments if message_params?
    @message.save!
    Rails.logger.info('[IncomingMessageService] Сообщение сохранено успешно')
  end

  private

  def set_contact
    Rails.logger.info('[IncomingMessageService] Начато выполнение set_contact')
    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: telegram_params_from_id,
      inbox: inbox,
      contact_attributes: contact_attributes
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
    Rails.logger.info("[IncomingMessageService] Контакт установлен: #{@contact.id}")
  end

  def process_message_attachments
    Rails.logger.info('[IncomingMessageService] Начато выполнение process_message_attachments')
    attach_location
    attach_files
    attach_contact
    Rails.logger.info('[IncomingMessageService] Завершено выполнение process_message_attachments')
  end

  def update_contact_avatar
    Rails.logger.info('[IncomingMessageService] Начато выполнение update_contact_avatar')
    if @contact.avatar.attached?
      Rails.logger.info('[IncomingMessageService] Аватар уже прикреплён, пропускаем')
      return
    end

    avatar_url = inbox.channel.get_telegram_profile_image(telegram_params_from_id)
    if avatar_url
      Rails.logger.info("[IncomingMessageService] Найден URL аватара: #{avatar_url}")
      ::Avatar::AvatarFromUrlJob.perform_later(@contact, avatar_url)
    else
      Rails.logger.info('[IncomingMessageService] URL аватара не найден')
    end
  end

  def conversation_params
    Rails.logger.info('[IncomingMessageService] Формирование параметров беседы')
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: conversation_additional_attributes
    }
  end

  def set_conversation
    Rails.logger.info('[IncomingMessageService] Начато выполнение set_conversation')
    @conversation = @contact_inbox.conversations.first
    if @conversation
      Rails.logger.info("[IncomingMessageService] Беседа найдена: #{@conversation.id}")
      return
    end

    @conversation = ::Conversation.create!(conversation_params)
    Rails.logger.info("[IncomingMessageService] Создана новая беседа: #{@conversation.id}")
  end

  def contact_attributes
    Rails.logger.info('[IncomingMessageService] Формирование параметров контакта')
    {
      name: "#{telegram_params_first_name} #{telegram_params_last_name}",
      additional_attributes: additional_attributes
    }
  end

  def additional_attributes
    {
      username: telegram_params_username,
      language_code: telegram_params_language_code,
      social_telegram_user_id: telegram_params_from_id,
      social_telegram_user_name: telegram_params_username
    }
  end

  def conversation_additional_attributes
    {
      chat_id: telegram_params_chat_id
    }
  end

  def file_content_type
    Rails.logger.info('[IncomingMessageService] Определение типа файла')
    return :image if params[:message][:photo].present? || params.dig(:message, :sticker, :thumb).present?
    return :audio if params[:message][:voice].present? || params[:message][:audio].present?
    return :video if params[:message][:video].present?

    file_type(params[:message][:document][:mime_type])
  end

  def attach_files
    Rails.logger.info('[IncomingMessageService] Начато выполнение attach_files')
    return unless file

    file_download_path = inbox.channel.get_telegram_file_path(file[:file_id])
    if file_download_path.blank?
      Rails.logger.info "[IncomingMessageService] Путь загрузки файла пуст для #{file[:file_id]} : inbox_id: #{inbox.id}"
      return
    end

    attachment_file = Down.download(file_download_path)
    Rails.logger.info("[IncomingMessageService] Файл скачан: #{attachment_file.original_filename}")

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type,
      file: {
        io: attachment_file,
        filename: attachment_file.original_filename,
        content_type: attachment_file.content_type
      }
    )
    Rails.logger.info('[IncomingMessageService] Файл прикреплен к сообщению')
  end

  def attach_location
    Rails.logger.info('[IncomingMessageService] Начато выполнение attach_location')
    return unless location

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: :location,
      fallback_title: location_fallback_title,
      coordinates_lat: location['latitude'],
      coordinates_long: location['longitude']
    )
    Rails.logger.info('[IncomingMessageService] Локация прикреплена к сообщению')
  end

  def attach_contact
    Rails.logger.info('[IncomingMessageService] Начато выполнение attach_contact')
    return unless contact_card

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: :contact,
      fallback_title: contact_card['phone_number'].to_s,
      meta: {
        first_name: contact_card['first_name'],
        last_name: contact_card['last_name']
      }
    )
    Rails.logger.info('[IncomingMessageService] Контакт прикреплен к сообщению')
  end

  def file
    Rails.logger.info('[IncomingMessageService] Определение файла')
    @file ||= visual_media_params || params[:message][:voice].presence || params[:message][:audio].presence || params[:message][:document].presence
  end

  def location_fallback_title
    Rails.logger.info('[IncomingMessageService] Определение fallback_title для location')
    return '' if venue.blank?

    venue[:title] || ''
  end

  def venue
    @venue ||= params.dig(:message, :venue).presence
  end

  def location
    Rails.logger.info('[IncomingMessageService] Определение location')
    @location ||= params.dig(:message, :location).presence
  end

  def contact_card
    Rails.logger.info("[IncomingMessageService] Определение contact_card. Полные параметры: #{params.inspect}")
    @contact_card ||= params.dig(:message, :contact).presence
  end

  def visual_media_params
    Rails.logger.info('[IncomingMessageService] Определение визуальных медиа параметров')
    params[:message][:photo].presence&.last || params.dig(:message, :sticker, :thumb).presence || params[:message][:video].presence
  end
end
